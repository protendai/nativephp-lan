<?php

namespace Protendai\Lan\Events;

use Illuminate\Foundation\Events\Dispatchable;
use Illuminate\Queue\SerializesModels;

/**
 * The receive server could not start (both ports busy), its listener failed,
 * or discovery failed (e.g. iOS without the multicast entitlement).
 */
class ServerError
{
    use Dispatchable, SerializesModels;

    public function __construct(
        public ?string $message = null,
    ) {}
}
