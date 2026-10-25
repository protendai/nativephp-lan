<?php

use Protendai\Lan\Events\FilesPicked;
use Protendai\Lan\Events\FilesPicking;
use Protendai\Lan\Events\PeerFound;
use Protendai\Lan\Events\ServerError;
use Protendai\Lan\Events\SessionCancelled;
use Protendai\Lan\Events\UploadComplete;
use Protendai\Lan\Events\UploadProgress;
use Protendai\Lan\Events\UploadRequested;

/*
 * NativePHP builds events from the native JSON payload by named arguments;
 * every documented payload must construct its class.
 */

it('builds PeerFound', function () {
    $event = new PeerFound(...['alias' => 'Phone', 'fingerprint' => 'fp', 'ip' => '192.168.1.5', 'port' => 53530, 'protocol' => 'http', 'deviceModel' => 'Pixel', 'deviceType' => 'mobile']);

    expect($event->ip)->toBe('192.168.1.5')->and($event->port)->toBe(53530);
});

it('builds UploadRequested with the remote IP', function () {
    $event = new UploadRequested(...[
        'requestId' => 'req-1',
        'sender' => ['alias' => 'Laptop', 'fingerprint' => 'fp', 'ip' => '192.168.1.7'],
        'files' => [['id' => 'f1', 'fileName' => 'a.jpg', 'size' => 10, 'fileType' => 'image/jpeg']],
        'pinProvided' => '1234',
        'remoteIp' => '192.168.1.7',
    ]);

    expect($event->remoteIp)->toBe('192.168.1.7')
        ->and($event->sender['ip'])->toBe('192.168.1.7')
        ->and($event->files[0]['id'])->toBe('f1');
});

it('builds UploadRequested from a payload without a PIN', function () {
    expect((new UploadRequested(...['requestId' => 'r', 'sender' => [], 'files' => [], 'remoteIp' => '10.0.0.2']))->pinProvided)->toBeNull();
});

it('builds progress and completion events', function () {
    $progress = new UploadProgress(...['sessionId' => 's', 'fileId' => 'f', 'bytesReceived' => 5, 'bytesTotal' => 10]);
    $complete = new UploadComplete(...['sessionId' => 's', 'fileId' => 'f', 'path' => 'content://media/external/downloads/1']);

    expect($progress->bytesTotal)->toBe(10)->and($complete->path)->toStartWith('content://');
});

it('builds SessionCancelled for sessions and for unanswered requests', function (array $payload) {
    $event = new SessionCancelled(...$payload);

    expect($event->reason)->toBe($payload['reason']);
})->with([
    'sender cancel' => [['sessionId' => 's', 'reason' => SessionCancelled::SENDER]],
    'interrupted' => [['sessionId' => 's', 'reason' => SessionCancelled::INTERRUPTED]],
    'timeout' => [['requestId' => 'r', 'reason' => SessionCancelled::TIMEOUT]],
    'withdrawn' => [['requestId' => 'r', 'reason' => SessionCancelled::SENDER]],
    'stopped' => [['sessionId' => 's', 'reason' => SessionCancelled::STOPPED]],
    'storage' => [['sessionId' => 's', 'reason' => SessionCancelled::STORAGE]],
]);

it('builds the remaining events', function () {
    expect((new ServerError(...['message' => 'boom']))->message)->toBe('boom')
        ->and((new FilesPicking(...['count' => 2]))->count)->toBe(2)
        ->and((new FilesPicked(...['files' => [['path' => '/p', 'name' => 'n', 'size' => 1]]]))->files)->toHaveCount(1);
});

it('uses every reason native code sends', function () {
    preg_match_all('/"reason"[,:)\s]+(?:\.put\(\s*)?"?(\w+)"/', kotlinSources().swiftSources(), $m);
    preg_match_all('/cancelSession\([^,]+,\s*(?:reason:\s*)?(?:if \([^)]*\) )?"(\w+)"/', kotlinSources().swiftSources(), $m2);
    preg_match_all('/reason: (?:full \? )?"(\w+)"(?: : "(\w+)")?/', swiftSources(), $m3);

    $reasons = array_filter(array_unique(array_merge($m[1], $m2[1], $m3[1], $m3[2])));
    $constants = (new ReflectionClass(SessionCancelled::class))->getConstants();

    expect($reasons)->not->toBeEmpty();
    foreach ($reasons as $reason) {
        expect($constants)->toContain($reason);
    }
});
