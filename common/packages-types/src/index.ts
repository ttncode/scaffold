// shared types live here so the api and the web app cannot drift.
export interface HealthStatus {
  readonly status: 'ok';
  readonly version: string;
}
