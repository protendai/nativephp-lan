<?php

namespace Tuma\Lan\Events;

use Illuminate\Foundation\Events\Dispatchable;
use Illuminate\Queue\SerializesModels;

class UploadComplete
{
    use Dispatchable, SerializesModels;

    public function __construct(
        public ?string $sessionId = null,
        public ?string $fileId = null,
        public ?string $path = null,
    ) {}
}
