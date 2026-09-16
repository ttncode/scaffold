<?php

use Illuminate\Support\Facades\Route;

// Loaded by bootstrap/app.php's withRouting(then: ...); laravel loads only
// web.php and api.php itself. The database driver splices in the probe; with
// --db none the throw stands and readiness reports 503.
Route::get('/health/ready', function () {
    try {
        // @DB_PROBE@
        throw new RuntimeException('no database is configured for this project');
    } catch (Throwable $e) {
        // Logged, not returned: the error names host and user, and this route is
        // unauthenticated. logger(), not Log: another `use` breaks pint's import
        // order once the driver splices in DB.
        logger()->warning('readiness probe failed: '.$e->getMessage());

        return response()->json(['status' => 'unavailable'], 503);
    }
});
