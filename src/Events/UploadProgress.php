<?php

namespace Protendai\Lan\Events;

use Illuminate\Foundation\Events\Dispatchable;
use Illuminate\Queue\SerializesModels;

/**
 * Bytes received so far for one file, at most twice a second.
 */
class UploadProgress
{
    use Dispatchable, SerializesModels;

    public function __construct(
        public ?string $sessionId = null,
        public ?string $fileId = null,
        public int $bytesReceived = 0,
        public int $bytesTotal = 0,
    ) {}
}
