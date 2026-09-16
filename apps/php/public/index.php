<?php

declare(strict_types=1);

// php-fpm front controller: one request, one Api, then everything is torn down.
require __DIR__ . '/../vendor/autoload.php';

Bench\Api::forRequest()->respond();
