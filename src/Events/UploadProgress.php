<?php

namespace Tuma\Lan\Events;

use Illuminate\Foundation\Events\Dispatchable;
use Illuminate\Queue\SerializesModels;

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
