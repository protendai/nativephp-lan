<?php

namespace Tuma\Lan\Events;

use Illuminate\Foundation\Events\Dispatchable;
use Illuminate\Queue\SerializesModels;

class SessionCancelled
{
    use Dispatchable, SerializesModels;

    /**
     * A session ended early, or (with only $requestId) a sender withdrew a
     * send request before it was answered.
     *
     * @param  string|null  $reason  One of: sender, interrupted, timeout, error.
     */
    public function __construct(
        public ?string $sessionId = null,
        public ?string $reason = null,
        public ?string $requestId = null,
    ) {}
}
