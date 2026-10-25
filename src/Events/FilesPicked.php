<?php

namespace Protendai\Lan\Events;

use Illuminate\Foundation\Events\Dispatchable;

/**
 * Files chosen in the multi-select picker, copied into the app cache.
 * Empty when the picker was cancelled.
 */
class FilesPicked
{
    use Dispatchable;

    /**
     * @param  list<array{path: string, name: string, size: int}>  $files
     */
    public function __construct(
        public array $files = [],
    ) {}
}
