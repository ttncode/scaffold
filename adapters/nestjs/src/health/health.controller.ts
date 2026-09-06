import { Controller, Get, HttpException, HttpStatus } from '@nestjs/common';

@Controller('health')
export class HealthController {
  @Get('live')
  live(): { status: string } {
    return { status: 'ok' };
  }

  // The probe is written by the selected service's driver: prisma has no
  // provider-agnostic read, so a SQL provider gets $queryRawUnsafe and
  // mongodb gets $runCommandRaw. A project generated with --db none keeps
  // the anchor's fallback and reports 503, because there is nothing here
  // that could honestly report ready.
  @Get('ready')
  async ready(): Promise<{ status: string }> {
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
