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
        return response()->json(['status' => 'unavailable', 'reason' => $e->getMessage()], 503);
    }
});
