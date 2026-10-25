<?php

namespace Protendai\Lan\Events;

use Illuminate\Foundation\Events\Dispatchable;
use Illuminate\Queue\SerializesModels;

/**
 * Another device of this service was seen: by multicast announcement, HTTP
 * subnet probe, sweep or its register call. $ip is always the address the
 * device was seen at, never a self-declared one. The same device is reported
 * repeatedly (every announcement); de-duplicate by $fingerprint.
 */
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
