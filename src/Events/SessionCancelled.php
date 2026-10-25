<?php

namespace Protendai\Lan\Events;

use Illuminate\Foundation\Events\Dispatchable;
use Illuminate\Queue\SerializesModels;

/**
 * A session ended early, or (with only $requestId) a send request ended
 * before it was answered.
 */
class SessionCancelled
{
    use Dispatchable, SerializesModels;

    /** The sender cancelled (POST cancel from the session's address, or withdrew its request). */
    public const SENDER = 'sender';

    /** This app called Lan::cancelSession(). */
    public const RECEIVER = 'receiver';

    /** The upload connection dropped or ended before the declared length. */
    public const INTERRUPTED = 'interrupted';

    /** PHP did not answer a request within config('lan.prepare_timeout'). */
    public const TIMEOUT = 'timeout';

    /** The disk filled up while receiving. */
    public const STORAGE = 'storage';

    /** Lan::stopServer() ended the session. */
    public const STOPPED = 'stopped';

    /** Writing the file failed for another reason. */
    public const ERROR = 'error';

    /**
     * @param  string|null  $reason  One of the constants above.
     */
    public function __construct(
        public ?string $sessionId = null,
        public ?string $reason = null,
        public ?string $requestId = null,
    ) {}
}
