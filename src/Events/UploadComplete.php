<?php

namespace Protendai\Lan\Events;

use Illuminate\Foundation\Events\Dispatchable;
use Illuminate\Queue\SerializesModels;

/**
 * One file arrived completely. $path is a file path, or on Android with a
 * public folder a content:// URI in Downloads.
 */
class UploadComplete
{
    use Dispatchable, SerializesModels;

    public function __construct(
        public ?string $sessionId = null,
        public ?string $fileId = null,
        public ?string $path = null,
    ) {}
}
