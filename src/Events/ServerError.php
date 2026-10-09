<?php

namespace Tuma\Lan\Events;

use Illuminate\Foundation\Events\Dispatchable;
use Illuminate\Queue\SerializesModels;

class ServerError
{
    use Dispatchable, SerializesModels;

    public function __construct(
        public ?string $message = null,
    ) {}
}
