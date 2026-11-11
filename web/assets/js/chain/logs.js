// Bounded log reads. Public RPC endpoints cap the block range of a log query,
// so the app reads only the recent past: LOG_LOOKBACK blocks, no further back
// than the contract's deployment.
export const LOG_LOOKBACK = 50_000;
export const LOG_CHUNK = 2_000;

// Logs matching `filter` from max(deployBlock, head - LOG_LOOKBACK) to head,
// oldest first. One query; if the endpoint refuses it, the same range again
// in LOG_CHUNK-block slices, where a refused slice is an error.
export async function recentLogs(contract, filter, deployBlock) {
  const head = await contract.runner.provider.getBlockNumber();
  const from = Math.max(Number(deployBlock) || 0, head - LOG_LOOKBACK);
  try {
    return await contract.queryFilter(filter, from, head);
  } catch {
    const logs = [];
    for (let start = from; start <= head; start += LOG_CHUNK) {
      logs.push(...await contract.queryFilter(filter, start, Math.min(start + LOG_CHUNK - 1, head)));
    }
    return logs;
  }
}
