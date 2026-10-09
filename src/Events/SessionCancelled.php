<?php

namespace Tuma\Lan\Events;

use Illuminate\Foundation\Events\Dispatchable;
use Illuminate\Queue\SerializesModels;

class SessionCancelled
{
    use Dispatchable, SerializesModels;

    /**
     * @param  string|null  $reason  One of: sender, timeout, error.
     */
    public function __construct(
        public ?string $sessionId = null,
        public ?string $reason = null,
    ) {}
}
