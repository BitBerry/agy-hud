#!/usr/bin/env node
/**
 * Detached quota fetcher for agy-hud.
 * Queries Antigravity LanguageServerService/RetrieveUserQuotaSummary (dual-window
 * weekly + 5h buckets) and GetUserStatus (tier/credits) and writes a sanitized
 * snapshot to quota.json (mode 0600, no email/name/CSRF tokens).
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

function resolveDataDir() {
  return (
    process.env.AGY_HUD_DATA_DIR ||
    process.env.PLUGIN_DATA ||
    path.join(os.homedir(), '.gemini', 'antigravity', 'plugin_data', 'agy-hud')
  );
}

function writeAtomic0600(filePath, dataObj) {
  const dir = path.dirname(filePath);
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const tmpPath = `${filePath}.${process.pid}.${Date.now()}.tmp`;
  fs.writeFileSync(tmpPath, JSON.stringify(dataObj, null, 2), { mode: 0o600 });
  try {
    fs.chmodSync(tmpPath, 0o600);
  } catch {
    // ignore
  }
  fs.renameSync(tmpPath, filePath);
}

async function postLS(lsAddress, csrfToken, method, bodyObj) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 3000);
  try {
    const res = await fetch(
      `http://${lsAddress}/exa.language_server_pb.LanguageServerService/${method}`,
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'x-codeium-csrf-token': csrfToken,
        },
        body: JSON.stringify(bodyObj),
        signal: controller.signal,
      }
    );
    if (!res.ok) return null;
    return await res.json();
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

async function main() {
  const lsAddress = process.env.ANTIGRAVITY_LS_ADDRESS || '';
  const csrfToken = process.env.ANTIGRAVITY_CSRF_TOKEN || '';
  if (!lsAddress || !csrfToken) {
    process.exit(0);
  }

  const dataDir = resolveDataDir();
  const quotaPath = path.join(dataDir, 'quota.json');

  const [summaryRes, statusRes] = await Promise.allSettled([
    postLS(lsAddress, csrfToken, 'RetrieveUserQuotaSummary', {}),
    postLS(lsAddress, csrfToken, 'GetUserStatus', {
      metadata: {
        ideName: 'antigravity',
        extensionName: 'antigravity',
        locale: 'en',
      },
    }),
  ]);

  const summaryPayload = summaryRes.status === 'fulfilled' ? summaryRes.value : null;
  const statusPayload = statusRes.status === 'fulfilled' ? statusRes.value : null;

  if (!summaryPayload && !statusPayload) {
    process.exit(0);
  }

  const rawGroups = Array.isArray(summaryPayload?.response?.groups)
    ? summaryPayload.response.groups
    : [];
  const summaryGroups = rawGroups.map((grp) => ({
    displayName: String(grp?.displayName || ''),
    description: grp?.description ? String(grp.description) : null,
    buckets: (Array.isArray(grp?.buckets) ? grp.buckets : []).map((b) => ({
      bucketId: String(b?.bucketId || ''),
      displayName: String(b?.displayName || ''),
      window: String(b?.window || ''),
      remainingFraction:
        typeof b?.remainingFraction === 'number' ? b.remainingFraction : 1.0,
      resetTime: b?.resetTime ? String(b.resetTime) : null,
      description: b?.description ? String(b.description) : null,
    })),
  }));

  const userStatus = statusPayload?.userStatus || {};
  const tierName =
    userStatus?.userTier?.name ||
    userStatus?.planStatus?.planInfo?.planName ||
    'Unknown';

  const rawCredits = Array.isArray(userStatus?.userTier?.availableCredits)
    ? userStatus.userTier.availableCredits
    : [];
  const availableCredits = rawCredits.map((c) => ({
    creditType: String(c?.creditType || ''),
    minimumCreditAmountForUsage: String(c?.minimumCreditAmountForUsage || ''),
  }));

  const planStatus = userStatus?.planStatus
    ? {
        availablePromptCredits:
          typeof userStatus.planStatus.availablePromptCredits === 'number'
            ? userStatus.planStatus.availablePromptCredits
            : null,
        availableFlowCredits:
          typeof userStatus.planStatus.availableFlowCredits === 'number'
            ? userStatus.planStatus.availableFlowCredits
            : null,
      }
    : null;

  const rawConfigs = Array.isArray(userStatus?.cascadeModelConfigData?.clientModelConfigs)
    ? userStatus.cascadeModelConfigData.clientModelConfigs
    : [];
  const models = rawConfigs.map((cfg) => ({
    label: String(cfg?.label || ''),
    modelId: String(cfg?.modelId || ''),
    remainingFraction:
      typeof cfg?.quotaInfo?.remainingFraction === 'number'
        ? cfg.quotaInfo.remainingFraction
        : null,
    resetTime: cfg?.quotaInfo?.resetTime ? String(cfg.quotaInfo.resetTime) : null,
    tagTitle: cfg?.tagTitle ? String(cfg.tagTitle) : null,
  }));

  const sanitized = {
    updatedAtMs: Date.now(),
    tierName: String(tierName),
    availableCredits,
    planStatus,
    summaryGroups,
    models,
  };

  writeAtomic0600(quotaPath, sanitized);
}

main().catch(() => process.exit(0));
