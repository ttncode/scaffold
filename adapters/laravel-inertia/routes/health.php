<?php

use Illuminate\Support\Facades\Route;

// Registered from bootstrap/app.php's withRouting(then: ...) — laravel loads
// only routes/web.php and routes/api.php on its own, so a file dropped here
// with nothing pointing at it would 404 forever.
//
// The probe is written by the selected service's driver: laravel has no
// provider-agnostic read, so a SQL connection gets `select 1` and mongodb
// gets a ping command. A project generated with --db none keeps the
// anchor's fallback and reports 503, because there is nothing here that
// could honestly report ready.
Route::get('/health/ready', function () {
    try {
        // @DB_PROBE@
        throw new RuntimeException('no database is configured for this project');
    } catch (Throwable $e) {
        // Logged, not returned: a driver's connection error names the host,
        // port, user and database, and /health/ready is unauthenticated. An
        // orchestrator reads the status code and nothing else. logger(), not
        // the Log facade: an import here would sit between the two `use`
        // lines services/mongodb/drivers/laravel.sh splices, and pint's
        // ordered_imports would then fail the generated project's own format
        // task.
        logger()->warning('readiness probe failed: '.$e->getMessage());

        return response()->json(['status' => 'unavailable'], 503);
    }
});
