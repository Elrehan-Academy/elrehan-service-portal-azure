<?php
/**
 * Elrehan Service Portal branding extension.
 *
 * Copyright (C) 2026 Mohamed Elrehan
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

SetupWebPage::AddModule(
    __FILE__,
    'elrehan-service-portal/0.2.1',
    array(
        'label' => 'Elrehan Service Portal Branding',
        'category' => 'application',
        'dependencies' => array(),
        'mandatory' => false,
        'visible' => true,

        // XML datamodel files are discovered and compiled separately by iTop.
        // Only PHP runtime model files belong in this array.
        'datamodel' => array(),

        'webservice' => array(),
        'data.struct' => array(),
        'data.sample' => array(),
        'doc.manual_setup' => '',
        'doc.more_information' => '',
        'settings' => array(),
    )
);
