import {
  Controller,
  Get,
  HttpException,
  HttpStatus,
  Logger,
} from '@nestjs/common';

@Controller('health')
export class HealthController {
  private readonly logger = new Logger(HealthController.name);

  // The database driver splices in the client and the probe; with --db none the
  // probe throws and readiness reports 503.
  // @DB_CLIENT@

  @Get('live')
  live(): { status: string } {
    return { status: 'ok' };
  }

  // Reuses the singleton's client: readiness is polled every few seconds.
  // Not `async`: with --db none, require-await fails lint; the driver adds it.
  @Get('ready')
  ready(): Promise<{ status: string }> {
    try {
      // @DB_PROBE@
      throw new Error('no database is configured for this project');
    } catch (error) {
      // Logged, not returned: the error names host and user, and this route is
      // unauthenticated.
      this.logger.warn(`readiness probe failed: ${(error as Error).message}`);
      throw new HttpException(
        { status: 'unavailable' },
        HttpStatus.SERVICE_UNAVAILABLE,
      );
    }
  }
}
