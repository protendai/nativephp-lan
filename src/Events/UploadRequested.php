<?php

namespace Tuma\Lan\Events;

use Illuminate\Foundation\Events\Dispatchable;
use Illuminate\Queue\SerializesModels;

/**
 * A sender asked to upload files. Native parks the request until PHP answers
 * with Lan::respond(). If PHP does not answer within 60s native replies 403.
 */
class UploadRequested
{
    use Dispatchable, SerializesModels;

    /**
     * @param  array<string, mixed>  $sender  { alias, fingerprint, ip, deviceType }
     * @param  list<array<string, mixed>>  $files  [{ id, fileName, size, fileType }]
     */
    public function __construct(
        public ?string $requestId = null,
        public array $sender = [],
        public array $files = [],
        public ?string $pinProvided = null,
    ) {}
}
