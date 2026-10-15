export interface RuntimeConfig {
  apiUrl: string;
}

// Fetched at run time, not read from import.meta.env: a VITE_* value is baked
// into the bundle at build time, and one image must serve every environment
// (toolbox ADR-0014).
export async function loadConfig(): Promise<RuntimeConfig> {
  const response = await fetch("/config.json");
  if (!response.ok) {
    throw new Error(`/config.json answered ${response.status}`);
  }
  return (await response.json()) as RuntimeConfig;
}
