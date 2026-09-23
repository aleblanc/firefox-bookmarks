/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

package org.mozilla.fenix.components

import mozilla.components.concept.engine.webextension.WebExtensionRuntime
import mozilla.components.support.base.log.logger.Logger

object SymfonyBuiltInExtensions {
    private val logger = Logger("firelex-builtin")

    private const val UBLOCK_ID = "uBlock0@raymondhill.net"
    private const val UBLOCK_URL = "resource://android/assets/extensions/ublock/"

    private const val SYMFONY_ID = "sfbookmarks-sync@aleblanc"
    private const val SYMFONY_URL = "resource://android/assets/extensions/symfony-bookmarks/"
    private const val DASHBOARD_PAGE = "dashboard.html"

    /** moz-extension:// URL of the Symfony dashboard, resolved once the extension is installed. */
    @Volatile
    var dashboardUrl: String? = null
        private set

    fun install(runtime: WebExtensionRuntime) {
        runtime.installBuiltInWebExtension(
            UBLOCK_ID,
            UBLOCK_URL,
            onSuccess = { logger.debug("Installed uBlock Origin: ${it.id} settings: ${it.getMetadata()?.baseUrl}dashboard.html") },
            onError = { throwable -> logger.error("Failed to install uBlock Origin", throwable) },
        )
        runtime.installBuiltInWebExtension(
            SYMFONY_ID,
            SYMFONY_URL,
            onSuccess = { extension ->
                val base = extension.getMetadata()?.baseUrl
                if (base != null) {
                    dashboardUrl = base + DASHBOARD_PAGE
                    logger.debug("Symfony dashboard resolved at $dashboardUrl")
                } else {
                    logger.error("Symfony extension installed but baseUrl is null")
                }
            },
            onError = { throwable -> logger.error("Failed to install Symfony Bookmarks", throwable) },
        )
    }
}
