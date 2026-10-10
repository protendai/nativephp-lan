<?php

namespace Tuma\Lan\Commands;

use Native\Mobile\Plugins\Commands\NativePluginHookCommand;

/**
 * post_compile hook: put Tumira's App Store privacy manifest
 * (PrivacyInfo.xcprivacy) into the iOS app bundle. NativePHP only copies a
 * plugin's .swift files, and the app ships no manifest of its own.
 */
class CopyPrivacyManifest extends NativePluginHookCommand
{
    protected $signature = 'tuma:lan:privacy-manifest';

    protected $description = "Copy Tumira's PrivacyInfo.xcprivacy into the iOS bundle";

    public function handle(): int
    {
        if (! $this->isIos()) {
            return self::SUCCESS;
        }

        if (! $this->copyToIosBundle('ios-bundle/PrivacyInfo.xcprivacy', 'PrivacyInfo.xcprivacy')) {
            $this->warn('Could not copy PrivacyInfo.xcprivacy into the iOS bundle.');
        }

        return self::SUCCESS;
    }
}
