<?php

namespace Tuma\Lan\Facades;

use Illuminate\Support\Facades\Facade;

/**
 * @method static void startDiscovery(array $deviceInfo)
 * @method static void stopDiscovery()
 * @method static void wakeQueue()
 * @method static void pickFiles(array $mimeTypes = []) Multi-select document picker (defaults to any type)
 * @method static void pickMedia() Multi-select photo/video picker
 * @method static bool thumbnail(string $source, string $dest, ?string $mime = null, int $size = 256)
 * @method static int|null startServer(array $deviceInfo, string $incomingDir, ?string $certPem = null, ?string $keyPem = null, ?string $publicFolder = null)
 * @method static void stopServer()
 * @method static void respond(string $requestId, array $acceptedFileIds, ?string $sessionId = null, int $status = 200)
 * @method static void cancelSession(string $sessionId)
 * @method static ?string localIp()
 * @method static bool openFile(string $uri, ?string $mime = null)
 * @method static void setAppearance(string $mode)
 *
 * @see \Tuma\Lan\Lan
 */
class Lan extends Facade
{
    protected static function getFacadeAccessor(): string
    {
        return 'tuma.lan';
    }
}
