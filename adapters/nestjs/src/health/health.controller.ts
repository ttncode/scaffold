import { Controller, Get, HttpException, HttpStatus } from '@nestjs/common';

@Controller('health')
export class HealthController {
  // The client field and the probe below are both written by the selected
  // service's driver: prisma has no provider-agnostic read, so a SQL
  // provider gets $queryRawUnsafe and mongodb gets $runCommandRaw. A project
  // generated with --db none leaves this anchor as a comment and the probe
  // falls through to its throw, reporting 503 honestly.
  // @DB_CLIENT@

  @Get('live')
  live(): { status: string } {
    return { status: 'ok' };
  }

  // Readiness is polled by every orchestrator, often every few seconds, so
  // the probe below reuses the client field declared above instead of
  // constructing a new PrismaClient per request: HealthController is a
  // Nest singleton (the default provider/controller scope), so one instance
  // — and one connection pool — lives for the process, the same lifetime a
  // NestJS Prisma integration normally gives it via a connect-once service.
  // A fresh client per call would need its own $disconnect() to avoid
  // leaking a connection per poll, but tearing a real pool down and back up
  // every few seconds is the wasteful version of the same fix.
  // Not `async` here: with --db none there is nothing to await, and
  // @typescript-eslint/require-await fails a generated project on its own
  // lint. services/shared/nest.sh adds the keyword when it splices in a
  // probe, which is the only case that awaits anything.
  @Get('ready')
  ready(): Promise<{ status: string }> {
    try {
      // @DB_PROBE@
      throw new Error('no database is configured for this project');
    } catch (error) {
      throw new HttpException(
        { status: 'unavailable', reason: (error as Error).message },
        HttpStatus.SERVICE_UNAVAILABLE,
      );
    }
  }
}
