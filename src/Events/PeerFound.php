<?php

namespace Tuma\Lan\Events;

use Illuminate\Foundation\Events\Dispatchable;
use Illuminate\Queue\SerializesModels;

class PeerFound
{
    use Dispatchable, SerializesModels;

    public function __construct(
        public ?string $alias = null,
        public ?string $fingerprint = null,
        public ?string $ip = null,
        public ?int $port = null,
        public ?string $protocol = null,
        public ?string $deviceModel = null,
        public ?string $deviceType = null,
    ) {}
}
