<?php

namespace Protendai\Lan\Facades;

use Illuminate\Support\Facades\Facade;

/**
 * @method static void startDiscovery(array $deviceInfo, array $options = [])
 * @method static void stopDiscovery()
 * @method static void sweepSubnet(array $deviceInfo, string $prefix, int $seconds = 20, array $options = [])
 * @method static void announce(array $deviceInfo, string $host, ?int $port = null, int $seconds = 20, array $options = [])
 * @method static int|null startServer(array $deviceInfo, string $incomingDir, ?string $publicFolder = null, array $options = [])
 * @method static void stopServer()
 * @method static bool respond(string $requestId, array $acceptedFileIds = [], ?string $sessionId = null, int $status = 200)
 * @method static bool accept(string $requestId, array $fileIds, string $sessionId)
 * @method static bool decline(string $requestId, int $status = 403)
 * @method static bool cancelSession(string $sessionId)
 * @method static string|null localIp()
 * @method static bool wifiEnabled()
 * @method static void pickFiles(array $mimeTypes = ['*\/*'])
 * @method static void pickMedia()
 * @method static bool thumbnail(string $source, string $dest, ?string $mime = null, int $size = 256)
 * @method static bool openFile(string $uri, ?string $mime = null)
 * @method static array config(array $options = [])
 * @method static array deviceInfo(array $deviceInfo, array $options = [])
 *
 * @see \Protendai\Lan\Lan
 */
class Lan extends Facade
{
    protected static function getFacadeAccessor(): string
    {
        return \Protendai\Lan\Lan::class;
    }
}
