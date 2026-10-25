<?php

namespace Protendai\Lan\Events;

use Illuminate\Foundation\Events\Dispatchable;

/**
 * The user chose $count files; they are being copied before FilesPicked.
 */
class FilesPicking
{
    use Dispatchable;

    public function __construct(
        public int $count = 0,
    ) {}
}
