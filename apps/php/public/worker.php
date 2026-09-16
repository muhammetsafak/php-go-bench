<?php

declare(strict_types=1);

// FrankenPHP worker: boot once, then serve requests from the same process until
// the server stops. The loop follows the shape in the FrankenPHP worker docs,
// including the collector call between requests.
require __DIR__ . '/../vendor/autoload.php';

ignore_user_abort(true);

$api = Bench\Api::forWorker();
$handler = static function () use ($api): void {
    $api->respond();
};

while (frankenphp_handle_request($handler)) {
    gc_collect_cycles();
}
