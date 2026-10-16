<?php
/**
 * Elrehan Service Portal UI branding.
 *
 * Copyright (C) 2026 Mohamed Elrehan
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

namespace Elrehan\ServicePortal\Hook;

use AbstractPortalUIExtension;
use Symfony\Component\DependencyInjection\Container;
use utils;

class PortalUIExtension extends AbstractPortalUIExtension
{
    /**
     * Load the ESP-owned portal stylesheet.
     *
     * @param Container $oContainer
     *
     * @return array
     */
    public function GetCSSFiles(Container $oContainer)
    {
        return array(
            utils::GetAbsoluteUrlModulesRoot()
            .'elrehan-service-portal/assets/css/esp-theme.css',
        );
    }
}
