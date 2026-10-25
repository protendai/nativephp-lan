<?php

/*
|--------------------------------------------------------------------------
| LAN transfer settings (protendai/nativephp-lan)
|--------------------------------------------------------------------------
|
| Two installs of your app only see each other when service_id, api_prefix,
| port and the multicast group/port all match. Pick your own values for your
| app (so it never answers devices of another app built on this plugin) and
| never change them after release: older installs would stop finding newer
| ones.
|
| Every Lan::start*() / announce / sweep call sends these to native code;
| the $options argument of those calls overrides them per call.
|
*/

return [

    // Marker in every device-info JSON ("app": ...). Devices with another value are ignored.
    'service_id' => env('LAN_SERVICE_ID', 'nativephp-lan'),

    // HTTP route prefix of the receive server: {prefix}/info, /register, /prepare-upload, /upload, /cancel.
    'api_prefix' => env('LAN_API_PREFIX', '/api/nativephp-lan/v1'),

    // TCP port of the receive server. When busy, port + 1 is tried and startServer() returns the bound one.
    'port' => (int) env('LAN_PORT', 53530),

    // UDP multicast group and port used for announcements.
    'multicast_group' => env('LAN_MULTICAST_GROUP', '224.0.0.170'),
    'multicast_port' => (int) env('LAN_MULTICAST_PORT', 53530),

    // Seconds a prepare-upload waits for Lan::respond(). Afterwards the sender gets
    // 403 ("timeout") and PHP gets SessionCancelled(requestId, reason: "timeout").
    'prepare_timeout' => 60,

    // Largest single file accepted, in bytes (0 = no limit). Larger files get 413.
    'max_file_size' => 0,

    // Most files in one send request (413 above it).
    'max_files' => 1000,

    // Most simultaneous connections to the receive server; extra ones are closed.
    'max_connections' => 32,

    // Wrong PINs (your app answering 401 to a request that carried a PIN) from one IP
    // before that IP is locked out: 10 s, doubling per further failure, up to 5 min.
    'pin_max_attempts' => 3,

];
