<?php

namespace Protendai\Lan\Events;

use Illuminate\Foundation\Events\Dispatchable;
use Illuminate\Queue\SerializesModels;

/**
 * A sender asked to upload files. Native parks the request until PHP answers
 * with Lan::respond() (or accept()/decline()). Without an answer within
 * config('lan.prepare_timeout') seconds the sender gets 403 and
 * SessionCancelled(requestId, reason: "timeout") follows.
 *
 * Security: $sender is self-declared by the sender, except $sender['ip'],
 * which native code overwrites with the address the request came from
 * ($remoteIp). Only skip the user's confirmation when the fingerprint AND
 * $remoteIp match a peer you discovered recently (see README).
 */
class UploadRequested
{
    use Dispatchable, SerializesModels;

    /**
     * @param  array<string, mixed>  $sender  { alias, fingerprint, deviceModel, deviceType, port, protocol, ip, ... }
     * @param  list<array<string, mixed>>  $files  [{ id, fileName, size, fileType, ... }]
     * @param  string|null  $pinProvided  The PIN the sender sent (?pin=), if any.
     * @param  string|null  $remoteIp  The IP address the request came from.
     */
    public function __construct(
        public ?string $requestId = null,
        public array $sender = [],
        public array $files = [],
        public ?string $pinProvided = null,
        public ?string $remoteIp = null,
    ) {}
}
