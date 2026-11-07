package com.elarni

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.graphics.drawable.toBitmap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

// The row is the switch, as in SettingsSwitch: TalkBack reads the title with its state, not a nameless switch.
@Composable fun ToggleField(title: String, checked: Boolean, detail: String = "", enabled: Boolean = true, change: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).toggleable(checked, enabled, Role.Switch, onValueChange = change), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
        Column(Modifier.weight(1f)) { Text(title, style = MaterialTheme.typography.bodyLarge); if (detail.isNotEmpty()) Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        Switch(checked, null, enabled = enabled)
    }
}

// A settings row with the value and its menu on the trailing edge, like the iPhone's menu pickers.
@Composable fun ChoiceField(title: String, selected: String, choices: List<String>, labels: List<String> = choices, enabled: Boolean = true, change: (String) -> Unit) {
    var open by remember { mutableStateOf(false) }
    val tint = if (enabled) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.38f)
    Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).clickable(enabled = enabled, role = Role.DropdownList) { open = true },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
        Text(title, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge, color = if (enabled) MaterialTheme.colorScheme.onSurface else tint)
        Box {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(labels.getOrNull(choices.indexOf(selected)) ?: selected, Modifier.widthIn(max = 200.dp), style = MaterialTheme.typography.bodyLarge, color = tint, textAlign = TextAlign.End)
                RouteIcon("unfold", color = tint)
            }
            DropdownMenu(open, { open = false }) { choices.forEachIndexed { index, value -> DropdownMenuItem({ Text(labels.getOrElse(index) { value }) }, { open = false; change(value) }, enabled = enabled, trailingIcon = { if (value == selected) RouteIcon("check") }) } }
        }
    }
}
// Settings pages use Android Settings' grouped look: a tile per row, rounder at each group's ends.
@Composable fun SettingsColumn(content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(top = 4.dp, bottom = 100.dp), verticalArrangement = Arrangement.spacedBy(8.dp), content = content)
}
@Composable fun SettingsGroup(title: String = "", footer: String = "", content: @Composable ColumnScope.() -> Unit) {
    Column {
        if (title.isNotEmpty()) Text(title, Modifier.padding(start = 20.dp, end = 20.dp, top = 12.dp, bottom = 8.dp).semantics { heading() }, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        // The group's clip rounds only the outer corners of its first and last tiles.
        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(24.dp)), verticalArrangement = Arrangement.spacedBy(2.dp), content = content)
        if (footer.isNotEmpty()) Text(footer, Modifier.padding(start = 20.dp, end = 20.dp, top = 8.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
@Composable fun SettingsTile(title: String, summary: String = "", icon: String = "", enabled: Boolean = true, titleColor: Color = MaterialTheme.colorScheme.onSurface,
    modifier: Modifier = Modifier, shape: Shape = RoundedCornerShape(4.dp), trailing: (@Composable () -> Unit)? = null, below: (@Composable () -> Unit)? = null, onClick: (() -> Unit)? = null) {
    val alpha = if (enabled) 1f else 0.38f
    Row(Modifier.fillMaxWidth().clip(shape).background(MaterialTheme.colorScheme.surfaceContainerHigh)
        .then(if (onClick != null) Modifier.clickable(enabled = enabled, onClick = onClick) else modifier)
        .heightIn(min = 56.dp).padding(horizontal = 20.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
        if (icon.isNotEmpty()) RouteIcon(icon, color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = alpha))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = MaterialTheme.typography.bodyLarge, color = titleColor.copy(alpha = alpha))
            if (summary.isNotEmpty()) Text(summary, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = alpha))
            below?.invoke()
        }
        trailing?.invoke()
    }
}
// A group drawn one lazy-list row at a time: each row rounds only the group's outer corners, as SettingsGroup's clip does.
fun segmentShape(index: Int, count: Int): Shape {
    val top = if (index == 0) 24.dp else 4.dp; val bottom = if (index == count - 1) 24.dp else 4.dp
    return RoundedCornerShape(top, top, bottom, bottom)
}
@Composable fun SettingsSwitch(title: String, checked: Boolean, summary: String = "", enabled: Boolean = true, change: (Boolean) -> Unit) =
    SettingsTile(title, summary, enabled = enabled, modifier = Modifier.toggleable(checked, enabled, Role.Switch, onValueChange = change), trailing = { Switch(checked, null, enabled = enabled) })
// Like Android's list preferences: the value is the summary and picking one closes the dialog.
@Composable fun SettingsChoice(title: String, selected: String, choices: List<String>, labels: List<String> = choices, enabled: Boolean = true,
    below: (@Composable () -> Unit)? = null, change: (String) -> Unit) {
    var open by rememberSaveable { mutableStateOf(false) }
    SettingsTile(title, labels.getOrNull(choices.indexOf(selected)) ?: selected, enabled = enabled, modifier = Modifier.clickable(enabled = enabled, role = Role.DropdownList) { open = true }, below = below)
    if (open) AlertDialog(onDismissRequest = { open = false }, title = { Text(title) }, confirmButton = {}, dismissButton = { TextButton({ open = false }) { Text(tr(R.string.cancel)) } },
        text = { Column(Modifier.selectableGroup()) { choices.forEachIndexed { index, value ->
            Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).selectable(value == selected, role = Role.RadioButton) { open = false; change(value) },
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                RadioButton(value == selected, null); Text(labels.getOrElse(index) { value }, style = MaterialTheme.typography.bodyLarge)
            }
        } } })
}
// Like Android's text preferences: the value is the summary and the dialog edits it.
@Composable fun SettingsText(title: String, value: String, summary: String = value, detail: String = "", number: Boolean = false, lines: Int = 1, enabled: Boolean = true, change: (String) -> Unit) {
    var open by rememberSaveable { mutableStateOf(false) }
    var draft by rememberSaveable(stateSaver = TextFieldValue.Saver) { mutableStateOf(TextFieldValue()) }
    // The cursor starts after the value, as in Android's EditTextPreference.
    SettingsTile(title, summary.ifEmpty { tr(R.string.not_set) }, enabled = enabled) { draft = TextFieldValue(value, TextRange(value.length)); open = true }
    if (open) {
        val focus = remember { FocusRequester() }
        AlertDialog(onDismissRequest = { open = false }, title = { Text(title) },
            text = { Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(draft, { draft = it }, Modifier.fillMaxWidth().focusRequester(focus), singleLine = lines == 1, minLines = lines, maxLines = if (lines == 1) 1 else 10,
                    keyboardOptions = KeyboardOptions(keyboardType = if (number) KeyboardType.Number else KeyboardType.Text, autoCorrectEnabled = false))
                if (detail.isNotEmpty()) Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                // The dialog composes in its own window, so focus is requested from inside it.
                LaunchedEffect(Unit) { focus.requestFocus() }
            } },
            confirmButton = { TextButton({ change(draft.text); open = false }) { Text(tr(R.string.ok)) } },
            dismissButton = { TextButton({ open = false }) { Text(tr(R.string.cancel)) } })
    }
}
@Composable private fun EditorActions(busy: Boolean, cancel: () -> Unit, save: () -> Unit, label: String = tr(R.string.save_changes)) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp, Alignment.End)) {
        TextButton(cancel, enabled = !busy) { Text(tr(R.string.cancel)) }
        Button(save, enabled = !busy) { Text(label) }
    }
}
@Composable private fun TextField(label: String, value: String, lines: Int = 1, change: (String) -> Unit) {
    OutlinedTextField(value, change, label = { Text(label) }, modifier = Modifier.fillMaxWidth(), minLines = lines, maxLines = if (lines == 1) 1 else 10,
        keyboardOptions = KeyboardOptions(autoCorrectEnabled = false))
}
@Composable private fun Section(title: String, expanded: Boolean = false, content: @Composable ColumnScope.() -> Unit) {
    var open by rememberSaveable { mutableStateOf(expanded) }
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        HorizontalDivider()
        TextButton({ open = !open }, modifier = Modifier.fillMaxWidth()) { Text(if (open) tr(R.string.close_2, title) else title, style = MaterialTheme.typography.titleMedium) }
        if (open) content()
    }
}
private fun lines(value: String) = value.lines().map(String::trim).filter(String::isNotEmpty).distinct()
@Composable private fun rememberDraft(activity: MainActivity, key: String, initial: () -> String) = remember(activity.interaction, key) { activity.interaction.draft(key, initial) }

@Composable fun SettingsEditor(catalog: Catalog, section: String, busy: Boolean, activity: MainActivity,
    navigate: (String, String) -> Unit, openServers: () -> Unit, done: () -> Unit) {
    val saved = catalog.settings
    val fields = Settings.fields.filter { it.section == section }
    val current = buildMap {
        fields.forEach { put(it.key, saved.get(it.key).toString()) }
        listOf("includedRoutes", "excludedRoutes", "trustedWiFiNetworks").forEach { put(it, saved.strings(it).joinToString("\n")) }
    }
    val values = remember(section, activity.interaction) { activity.interaction.fields("settings-$section") { current } }
    // What the draft started from: a save sends only the edits made here, so a setting changed elsewhere since, such as Home's sort, stays.
    val base = remember(section, activity.interaction) { activity.interaction.fields("settings-$section-base") { values.toMap() } }
    fun edited(key: String) = values[key] != base[key]
    var localError by remember { mutableStateOf<String?>(null) }
    var routesOpen by rememberSaveable { mutableStateOf(false) }
    var askOpenProxy by rememberSaveable { mutableStateOf(false) }
    val immediate = if (section == "General") setOf("onDemandEnabled", "disconnectOnSleep", "connectOnUntrustedWiFi", "expiryReminders", "allowExternalControl") else emptySet()
    var namesAllowed by remember { mutableStateOf(true) }
    LifecycleResumeEffect(activity.wifiAnswers) { namesAllowed = WiFiRule.namesAllowed(activity); onPauseOrDispose {} }
    @Composable fun toggle(item: SettingField) = SettingsSwitch(item.title, saved.optBoolean(item.key), item.detail, enabled = !busy) {
        activity.run("settings", obj("settings" to obj(item.key to it)))
        if (item.key == "connectOnUntrustedWiFi" && it && !WiFiRule.namesAllowed(activity)) activity.allowWiFiNames()
    }
    @Composable fun field(field: SettingField) {
        val value = (if (edited(field.key)) values[field.key] else current[field.key]) ?: field.initial.toString()
        when {
            // Shown inverted: dropping the login needs a warning; requiring one without a saved login generates it.
            field.key == "inboundAuthEnabled" -> SettingsSwitch(field.title, value != "true", field.detail, enabled = !busy) { allow ->
                if (allow) askOpenProxy = true else values[field.key] = "true"
            }
            field.initial is Boolean -> SettingsSwitch(field.title, value == "true", field.detail,
                enabled = !busy && (field.key != "allowLAN" || values["inboundAuthEnabled"] == "true")) {
                values[field.key] = it.toString()
            }
            field.choices.isNotEmpty() -> {
                val labels = when (field.key) {
                    "theme" -> listOf(tr(R.string.follow_system), tr(R.string.light), tr(R.string.dark))
                    "accent" -> listOf(tr(R.string.evergreen), tr(R.string.blue), tr(R.string.teal), tr(R.string.purple), tr(R.string.orange))
                    "preferredIP" -> listOf(tr(R.string.automatic), "IPv4", "IPv6")
                    "profilePreferredIP" -> listOf(tr(R.string.use_profile), tr(R.string.automatic), "IPv4", "IPv6")
                    "sort" -> listOf(tr(R.string.provider_order), tr(R.string.alphabetical), tr(R.string.lowest_latency))
                    "probeMode" -> listOf(tr(R.string.proxy), tr(R.string.current_rules_active_tunnel), tr(R.string.direct_tcp_2), tr(R.string.direct_icmp_2))
                    "probeVariant" -> listOf(tr(R.string.single_request), tr(R.string.double_request), "Keep-alive")
                    "profileDNSMode" -> listOf(tr(R.string.provider_profile), "1.1.1.1", tr(R.string.routing_profile))
                    else -> field.choices
                }
                SettingsChoice(field.title, value, field.choices, labels) {
                    values[field.key] = it
                    if (field.key == "profilePreferredIP" && it != "inherit") values["preferredIP"] = it
                }
            }
            else -> SettingsText(field.title, value, if (field.key == "subscriptionAutoUpdateHours") (if (value == "1") tr(R.string.every_hour) else trPlural(R.plurals.every_n_hours, value.toIntOrNull() ?: 0, value))
                else if (field.key == "updateFeedURL") value.ifEmpty { tr(R.string.off) } else value,
                field.detail, number = field.initial is Int, lines = if (field.key == "probeExpectedBody") 2 else 1) { values[field.key] = it }
        }
    }
    // App-wide addressing; each server's own choice lives in its details.
    val addressing = listOf("preferredIP", "profilePreferredIP")
    val listed = fields.filter { item -> item.key !in immediate && item.key !in addressing && item.key != "updateFeedURL" && section != "Apps & routes" &&
        !(item.key == "httpPort" && values["httpInboundEnabled"] != "true" ||
            item.key in listOf("fragmentPackets", "fragmentLength", "fragmentInterval") && values["fragmentationEnabled"] != "true" ||
            section == "Server tests" && item.key in listOf("probeMethod", "probeVariant", "probeURL", "probeExpectedStatus", "probeExpectedBody") && values["probeMode"] !in listOf("proxy", "activeProxy")) }
    SettingsColumn {
        if (section == "General") SettingsGroup(tr(R.string.connection_2)) {
            SettingsTile(tr(R.string.connection_recovery), if (catalog.data.mapObject("automation").optBoolean("enabled")) tr(R.string.on) else tr(R.string.off)) { navigate("automation", "") }
            fields.filter { it.key in immediate && it.key != "allowExternalControl" }.forEach { toggle(it) }
            if (saved.optBoolean("connectOnUntrustedWiFi")) {
                SettingsText(tr(R.string.trusted_wi_fi_networks), values["trustedWiFiNetworks"] ?: "", lines(values["trustedWiFiNetworks"] ?: "").joinToString(", ")
                    .ifEmpty { tr(R.string.none_every_wi_fi_network_connects) }, tr(R.string.one_network_name_per_line), lines = 3) { values["trustedWiFiNetworks"] = it }
                if (!namesAllowed) SettingsTile(tr(R.string.allow_location_all_the_time), tr(R.string.android_shows_wi_fi_names_only),
                    trailing = { TextButton({ activity.allowWiFiNames() }) { Text(tr(R.string.allow)) } })
            }
        }
        if (listed.isNotEmpty()) SettingsGroup(if (section == "General") tr(R.string.subscriptions) else "") {
            listed.forEach { field(it) }
            if (section == "Connection") {
                val login = catalog.data.optJSONObject("inboundCredentials")
                var shown by rememberSaveable { mutableStateOf(false) }
                SettingsTile(tr(R.string.proxy_login), login?.let { "${it.string("username")} · ${if (shown) it.string("password") else "••••••••••••"}" } ?: tr(R.string.not_configured),
                    trailing = login?.let { { Row {
                        TextButton({ shown = !shown }) { Text(if (shown) tr(R.string.hide_2) else tr(R.string.show)) }
                        TextButton({ activity.copy(it.string("password"), sensitive = true) }) { Text(tr(R.string.copy)) }
                    } } }) { navigate("credentials", "") }
                // Android owns the block; only a running VPN can read whether it is on.
                val lockdown = activity.repository.engine.service?.isLockdownEnabled
                SettingsTile(tr(R.string.block_traffic_without_vpn), listOfNotNull(lockdown?.let { if (it) tr(R.string.on) else tr(R.string.off) },
                    tr(R.string.android_manages_this_turn_on_always)).joinToString(" · "),
                    trailing = { TextButton({ activity.vpnSettings() }) { Text(tr(R.string.open)) } })
            }
            if (section == "Server tests") SettingsTile(tr(R.string.open_server_list), onClick = openServers)
        }
        if (section == "General") SettingsGroup(tr(R.string.updates), tr(R.string.elarni_reads_this_address_once_a)) {
            fields.filter { it.key == "updateFeedURL" }.forEach { field(it) }
        }
        if (section == "Connection") SettingsGroup(tr(R.string.server_addressing)) {
            fields.filter { it.key in addressing }.forEach { field(it) }
        }
        if (section == "Apps & routes") {
            SettingsGroup {
                SettingsTile(tr(R.string.per_app_routing), when (saved.string("perAppMode")) { "bypass" -> tr(R.string.bypass_listed_apps); "proxyOnly" -> tr(R.string.only_listed_apps); else -> tr(R.string.off) }) { navigate("perApp", "") }
                SettingsTile(tr(R.string.advanced_network_routes), tr(R.string.included_and_excluded_ip_ranges), trailing = { RouteIcon(if (routesOpen) "collapse" else "expand", color = MaterialTheme.colorScheme.onSurfaceVariant) }) { routesOpen = !routesOpen }
            }
            if (routesOpen) SettingsGroup(footer = tr(R.string.excluded_routes_bypass_this_vpn_always)) {
                fields.forEach { field(it) }
                listOf("includedRoutes" to tr(R.string.included_cidrs), "excludedRoutes" to tr(R.string.excluded_cidrs)).forEach { (key, title) ->
                    SettingsText(title, values[key] ?: "", lines(values[key] ?: "").joinToString(", ").ifEmpty { tr(R.string.none) }, tr(R.string.one_per_line), lines = 3) { values[key] = it }
                }
            }
        }
        if (section == "DNS" && values["profileDNSMode"] == "routing") {
            val enabled = catalog.routes.filter { it.optBoolean("enabled", true) }
            SettingsGroup(tr(R.string.routing_profiles), if (enabled.isEmpty()) tr(R.string.no_enabled_routing_profiles_enable_a) else "") {
                enabled.forEach { route -> SettingsTile(route.string("name"), tr(R.string.edit_dns)) { navigate("routeDNS", route.string("id")) } }
            }
        }
        if (section == "General") SettingsGroup(tr(R.string.android_integration)) {
            SettingsTile(tr(R.string.shortcuts)) { navigate("shortcuts", "") }
            fields.filter { it.key == "allowExternalControl" }.forEach { toggle(it) }
            catalog.data.string("externalControlKey").takeIf { saved.optBoolean("allowExternalControl") && it.isNotEmpty() }?.let { key ->
                SettingsTile(tr(R.string.control_key), key, trailing = { Row {
                    TextButton({ activity.copy(key, sensitive = true) }) { Text(tr(R.string.copy)) }
                    TextButton({ activity.run("newControlKey") }, enabled = !busy) { Text(tr(R.string.new_key)) }
                } })
            }
            SettingsTile(tr(R.string.android_vpn_settings)) { activity.vpnSettings() }
            SettingsTile(tr(R.string.app_notifications_battery)) { activity.appSettings() }
            SettingsTile(tr(R.string.open_source_notices)) { navigate("notices", "") }
        }
        localError?.let { Text(it, Modifier.padding(horizontal = 20.dp), color = MaterialTheme.colorScheme.error) }
        if (askOpenProxy) {
            val ports = if (values["httpInboundEnabled"] == "true") tr(R.string.ports_a_and_b, values["socksPort"], values["httpPort"]) else tr(R.string.port_a, values["socksPort"])
            AlertDialog(onDismissRequest = { askOpenProxy = false }, title = { Text(tr(R.string.allow_apps_without_a_login)) },
                text = { Text(tr(R.string.in_local_proxy_mode_any_app, ports)) },
                confirmButton = { TextButton({ askOpenProxy = false; values["inboundAuthEnabled"] = "false"; values["allowLAN"] = "false" },
                    colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)) { Text(tr(R.string.allow_without_login)) } },
                dismissButton = { TextButton({ askOpenProxy = false }) { Text(tr(R.string.cancel)) } })
        }
        // Apps & routes saves only the route fields, which show while their section is open.
        if (section != "Apps & routes" || routesOpen) EditorActions(busy, done, {
            try {
                val patch = JSONObject()
                fields.filter { it.key !in immediate && edited(it.key) }.forEach { item -> patch.put(item.key, when (item.initial) {
                    is Boolean -> values[item.key] == "true"
                    is Int -> values[item.key]?.toIntOrNull() ?: throw AppFailure("invalid_settings")
                    else -> values[item.key]
                }) }
                if (section == "Apps & routes") listOf("includedRoutes", "excludedRoutes").filter(::edited).forEach { patch.put(it, JSONArray(lines(values[it] ?: ""))) }
                if (section == "General" && edited("trustedWiFiNetworks")) patch.put("trustedWiFiNetworks", JSONArray(lines(values["trustedWiFiNetworks"] ?: "")))
                localError = null
                // The editor stays open, so what it saved is where later edits start from.
                val sent = values.filterKeys(::edited)
                activity.run("settings", obj("settings" to patch)) { base.putAll(sent) }
            } catch (_: Exception) { localError = tr(R.string.enter_valid_numbers_and_cidr_routes) }
        })
    }
}

@Composable fun CredentialsEditor(busy: Boolean, activity: MainActivity, done: () -> Unit) {
    var user by rememberDraft(activity, "proxy-user") { "" }; var password by rememberDraft(activity, "proxy-password") { "" }
    FormColumn {
        TextField(tr(R.string.username), user) { user = it }
        OutlinedTextField(password, { password = it }, label = { Text(tr(R.string.password)) }, visualTransformation = PasswordVisualTransformation(), singleLine = true, modifier = Modifier.fillMaxWidth(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
        EditorActions(busy, done, { activity.saveReviewed("credentials", obj("username" to user, "password" to password)) })
    }
}

/** Russian apps that refuse or degrade service over a VPN, by store package. */
val RUSSIAN_APPS = listOf("ru.rostel" to "Gosuslugi", "ru.ozon.app.android" to "Ozon", "com.wildberries.ru" to "Wildberries", "ru.oneme.app" to "MAX",
    "ru.sberbankmobile" to "Sber", "com.idamob.tinkoff.android" to "T-Bank", "ru.vtb24.mobilebanking.android" to "VTB", "ru.alfabank.mobile.android" to "Alfa-Bank")
// Instrumentation swaps in apps the emulator has.
@Volatile var russianApps = RUSSIAN_APPS

@Composable private fun ColumnScope.RussianAppsPreset(apps: List<JSONObject>, packages: List<String>, enabled: Boolean, add: (List<String>) -> Unit) {
    var open by rememberSaveable { mutableStateOf(false) }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(tr(R.string.presets), Modifier.weight(1f), color = MaterialTheme.colorScheme.onSurfaceVariant)
        FilterChip(open, { open = !open }, { Text(tr(R.string.russian_apps)) }, enabled = enabled)
    }
    if (!open) return
    val installed = apps.map { it.string("package") }.toSet()
    val candidates = russianApps.map { it.first }.filter { it in installed && it !in packages }
    var chosen by rememberSaveable(candidates) { mutableStateOf(candidates) }
    russianApps.forEach { (name, label) ->
        val available = enabled && name in candidates
        Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("preset-app-$name")
            .toggleable(name in chosen || name in packages, enabled = available, role = Role.Checkbox) { chosen = if (it) chosen + name else chosen - name },
            verticalAlignment = Alignment.CenterVertically) {
            Checkbox(name in chosen || name in packages, null, enabled = available)
            Text(label, Modifier.weight(1f))
            Text(when { name in packages -> tr(R.string.added); name in installed -> tr(R.string.installed); else -> tr(R.string.not_installed) },
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
    Button({ add(chosen); open = false }, Modifier.align(Alignment.End), enabled = enabled && chosen.isNotEmpty()) {
        Text(trPlural(R.plurals.add_apps, chosen.size))
    }
    val dark = MaterialTheme.colorScheme.surface == Color(0xFF202124)
    Text(tr(R.string.these_apps_connect_directly_but_they),
        Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(if (dark) Color(0xFF453810) else Color(0xFFFEF9C3)).padding(12.dp),
        color = if (dark) Color(0xFFFDE047) else Color(0xFF854D0E), style = MaterialTheme.typography.bodyMedium)
}

private fun targetMap(value: JSONObject?) = value?.let { map -> map.keys().asSequence().associateWith(map::getString) } ?: emptyMap()

@Composable fun PerAppEditor(saved: JSONObject, servers: List<Pair<String, String>>, busy: Boolean, activity: MainActivity, done: () -> Unit) {
    var mode by rememberSaveable { mutableStateOf(saved.string("perAppMode")) }
    var packages by rememberSaveable { mutableStateOf(saved.strings("perAppProcesses")) }
    var targets by rememberSaveable { mutableStateOf(targetMap(saved.optJSONObject("perAppTargets"))) }
    var proxyFor by rememberSaveable { mutableStateOf<String?>(null) }
    var query by rememberSaveable { mutableStateOf("") }
    var visibleCount by rememberSaveable(query) { mutableIntStateOf(8) }
    var apps by remember { mutableStateOf<List<JSONObject>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var manual by rememberDraft(activity, "per-app-manual") { packages.joinToString("\n") }
    var profile by rememberDraft(activity, "per-app-profile") { "" }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) {
        try { apps = activity.repository.execute("apps").objects("apps") }
        catch (_: Exception) { error = tr(R.string.couldn_t_load_installed_apps_reopen) }
        finally { loading = false }
    }
    val selectedApps = apps.filter { it.string("package") in packages }
    val available = apps.filter { it.string("package") !in packages && (it.string("name").contains(query, true) || it.string("package").contains(query, true)) }
    fun select(name: String, selected: Boolean) { packages = if (selected) (packages + name).distinct() else packages - name }
    // An app without a target of its own follows the mode.
    val modeTarget = if (mode == "bypass") "direct" else "routing"
    fun setTarget(app: String, target: String) { targets = targets - app + (if (target == modeTarget) emptyMap() else mapOf(app to target)) }
    fun label(target: String) = when {
        target == "direct" -> tr(R.string.direct)
        target == "routing" -> tr(R.string.follow_routing_rules)
        target == "block" -> tr(R.string.block)
        target.startsWith("proxy:") -> tr(R.string.local_proxy, runCatching { java.net.URI(target.substring(6)).rawAuthority }.getOrNull() ?: target.substring(6))
        target.startsWith("node:") -> servers.firstOrNull { "node:${it.first}" == target }?.let { tr(R.string.server, it.second) } ?: tr(R.string.missing_server)
        else -> target
    }
    Column(Modifier.fillMaxSize()) {
    LazyColumn(Modifier.weight(1f).testTag("per-app-list"), contentPadding = PaddingValues(horizontal = 24.dp, vertical = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        ChoiceField(tr(R.string.mode), mode, listOf("off", "bypass", "proxyOnly"), listOf(tr(R.string.off), tr(R.string.bypass_listed_apps), tr(R.string.only_listed_apps)), enabled = !busy) { mode = it }
        // Only listed apps already sends the others directly.
        if (mode != "proxyOnly") RussianAppsPreset(apps, packages, !busy && !loading) { added ->
            packages = (packages + added).distinct()
            if (mode == "off") mode = "bypass"
        }
        TextField(tr(R.string.search_installed_apps), query) { query = it }
        }
        }
        if (loading) item { Text(tr(R.string.loading_app_list), style = MaterialTheme.typography.bodySmall) }
        if (selectedApps.isNotEmpty()) item { Text(tr(R.string.selected_apps, selectedApps.size), style = MaterialTheme.typography.titleMedium) }
        items(selectedApps, key = { it.string("package") }) { app ->
            val name = app.string("package")
            Column {
                InstalledAppRow(app, true, !busy, activity) { select(name, it) }
                if (mode != "off") {
                    val current = targets[name] ?: modeTarget
                    // A deleted server stays shown until another target replaces it.
                    val choices = listOf("direct", "routing", "block") + servers.map { "node:${it.first}" } +
                        listOfNotNull(current.takeIf { it.startsWith("proxy:") || it.startsWith("node:") && servers.none { server -> "node:${server.first}" == it } }) + "ask-proxy"
                    Box(Modifier.testTag("per-app-target-$name")) {
                        ChoiceField(tr(R.string.traffic), current, choices, choices.map { if (it == "ask-proxy") tr(R.string.local_proxy_2) else label(it) }, enabled = !busy) { value ->
                            if (value == "ask-proxy") proxyFor = name else setTarget(name, value)
                        }
                    }
                }
            }
        }
        if (selectedApps.isNotEmpty() && mode != "off") item {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("per-app-other-apps"), verticalAlignment = Alignment.CenterVertically) {
                    Text(tr(R.string.other_apps), Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge)
                    Text(if (mode == "proxyOnly") tr(R.string.direct) else tr(R.string.follow_routing_rules), color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Text(tr(R.string.each_app_can_connect_directly_follow),
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        if (!loading) item { Text(if (query.isBlank()) tr(R.string.installed_apps) else tr(R.string.search_results), style = MaterialTheme.typography.titleMedium) }
        items(available.take(visibleCount), key = { it.string("package") }) { app -> InstalledAppRow(app, false, !busy, activity) { select(app.string("package"), it) } }
        if (available.isNotEmpty()) item {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(trPlural(R.plurals.showing_apps, available.size, minOf(visibleCount, available.size), available.size), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (visibleCount < available.size) OutlinedButton({ visibleCount += 8 }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text(tr(R.string.show_more)) }
            }
        } else if (!loading) item { Text(if (query.isBlank()) tr(R.string.no_other_installed_apps) else tr(R.string.no_apps_match_your_search), color = MaterialTheme.colorScheme.onSurfaceVariant) }
        item {
        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        val missing = packages.filter { name -> apps.none { it.string("package") == name } }
        if (!loading && missing.isNotEmpty()) Text(tr(R.string.not_currently_visible_remove_unavailable_apps, missing.joinToString()), color = MaterialTheme.colorScheme.error)
        Section(tr(R.string.package_profile_tools)) {
            TextField(tr(R.string.android_packages_one_per_line), manual, 4) { manual = it }
            TextButton({ packages = lines(manual) }) { Text(tr(R.string.use_package_list)) }
            TextField(tr(R.string.android_per_app_profile_json), profile, 4) { profile = it }
            TextButton({
                try {
                    val value = Settings.perAppProfile(profile)
                    mode = value.getString("mode"); packages = value.strings("processes"); targets = targetMap(value.optJSONObject("targets")); error = null
                } catch (_: Exception) { error = tr(R.string.use_a_valid_android_per_app) }
            }) { Text(tr(R.string.load_into_draft)) }
            TextButton({ activity.save(Settings.perAppExport(mode, packages, JSONObject(targets.filterKeys { it in packages })), "elarni-android-apps.json") }) { Text(tr(R.string.export_draft_profile)) }
        }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        }
        }
    }
        Surface {
            Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 12.dp)) {
                // A removed app takes its target with it.
                EditorActions(busy, done, { activity.saveReviewed("settings", obj("settings" to obj("perAppMode" to mode, "perAppProcesses" to JSONArray(packages),
                    "perAppTargets" to JSONObject(targets.filterKeys { it in packages }), "xrayTunEnabled" to (mode != "off" || saved.optBoolean("xrayTunEnabled"))))) })
            }
        }
    }
    proxyFor?.let { app ->
        ProxyDialog(targets[app]?.takeIf { it.startsWith("proxy:") }?.substring(6) ?: "socks5://127.0.0.1:1080", saved, { proxyFor = null }) { setTarget(app, "proxy:$it"); proxyFor = null }
    }
}

@Composable private fun ProxyDialog(initial: String, settings: JSONObject, dismiss: () -> Unit, use: (String) -> Unit) {
    var text by rememberSaveable { mutableStateOf(initial) }
    val error = Settings.perAppProxyError(text, settings)
    AlertDialog(onDismissRequest = dismiss, title = { Text(tr(R.string.local_proxy_2_2)) },
        confirmButton = { TextButton({ use(text.trim()) }, enabled = error == null) { Text(tr(R.string.use_proxy)) } },
        dismissButton = { TextButton(dismiss) { Text(tr(R.string.cancel)) } },
        text = { Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(tr(R.string.a_socks5_or_http_proxy_on))
            OutlinedTextField(text, { text = it }, label = { Text(tr(R.string.proxy_address)) }, singleLine = true, isError = error != null, modifier = Modifier.fillMaxWidth())
            error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
        } })
}

@Composable private fun InstalledAppRow(app: JSONObject, selected: Boolean, enabled: Boolean, activity: MainActivity, change: (Boolean) -> Unit) {
    val packageName = app.string("package")
    var icon by remember(packageName) { mutableStateOf<ImageBitmap?>(null) }
    LaunchedEffect(packageName) {
        icon = withContext(Dispatchers.IO) { runCatching { activity.packageManager.getApplicationIcon(packageName).toBitmap(96, 96).asImageBitmap() }.getOrNull() }
    }
    Row(Modifier.fillMaxWidth().heightIn(min = 64.dp).testTag("per-app-$packageName").toggleable(selected, enabled = enabled, role = Role.Checkbox, onValueChange = change),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        val description = tr(R.string.app_icon, app.string("name"))
        if (icon != null) Image(icon!!, description, Modifier.size(40.dp))
        else Box(Modifier.size(40.dp).semantics { contentDescription = description }, contentAlignment = Alignment.Center) { RouteIcon("apps", color = MaterialTheme.colorScheme.onSurfaceVariant) }
        Column(Modifier.weight(1f)) { Text(app.string("name"), style = MaterialTheme.typography.bodyLarge); Text(packageName, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        Checkbox(selected, null, enabled = enabled)
    }
}

@Composable fun RoutingEditor(record: JSONObject?, busy: Boolean, activity: MainActivity, initialSection: String = "", done: () -> Unit) {
    val original = record?.mapObject("profile") ?: obj("Name" to "My routing", "GlobalProxy" to "true", "RouteOrder" to "block-direct-proxy", "DomainStrategy" to "AsIs", "RemoteDNSType" to "DoU", "RemoteDNSIP" to "1.1.1.1", "DomesticDNSType" to "DoU", "DomesticDNSIP" to "1.1.1.1", "UseChunkFiles" to "true")
    val id = record?.string("id") ?: ""
    // The compiler falls back to a legacy RemoteDns/DomesticDns IP, which would bring back one cleared here; the form keeps only the current key.
    var encoded by rememberDraft(activity, "routing-$id") { original.copy().apply {
        for (prefix in listOf("Remote", "Domestic")) {
            val legacy = string("${prefix}Dns"); remove("${prefix}Dns")
            if (string("${prefix}DNSIP").isEmpty() && legacy.isNotEmpty()) put("${prefix}DNSIP", legacy)
        }
    }.toString() }
    val draft = remember(encoded) { JSONObject(encoded) }
    fun set(key: String, value: Any) { encoded = draft.copy().put(key, value).toString() }
    val listKeys = listOf("DirectSites", "DirectIp", "ProxySites", "ProxyIp", "BlockSites", "BlockIp", "DomesticDNSDomains")
    val inputs = remember(id, activity.interaction) { activity.interaction.fields("routing-fields-$id") { buildMap {
        listKeys.forEach { put(it, original.strings(it).joinToString("\n")) }
        put("DnsHosts", original.mapObject("DnsHosts").let { map -> map.keys().asSequence().sorted().joinToString("\n") { "$it=${map.getString(it)}" } })
    } } }
    var raw by rememberDraft(activity, "routing-json-$id") { original.toString(2) }
    var section by rememberDraft(activity, "routing-section-$id") { if (initialSection == "dns") "dns" else "rules" }
    var error by remember { mutableStateOf<String?>(null) }
    val jsonEditor = initialSection == "json"
    val hostRows = inputs["DnsHosts"].orEmpty().let { if (it.isEmpty()) emptyList() else it.lines().map { row -> row.split('=', limit = 2) } }
    fun updateHost(index: Int, part: Int, text: String) {
        inputs["DnsHosts"] = hostRows.mapIndexed { at, row -> if (at == index) {
            val values = mutableListOf(row.getOrElse(0) { "" }, row.getOrElse(1) { "" }); values[part] = text; values.joinToString("=")
        } else row.joinToString("=") }.joinToString("\n")
    }
    fun formContent(): String {
        val value = draft.copy()
        listKeys.filter { it != "DomesticDNSDomains" || draft.has(it) }.forEach { value.put(it, JSONArray(lines(inputs[it] ?: ""))) }
        val hosts = JSONObject(); val seen = mutableSetOf<String>()
        hostRows.forEach { row ->
            if (row.size != 2 || row.any { it.isBlank() } || !seen.add(row[0].trim().lowercase())) throw AppFailure("invalid_input")
            hosts.put(row[0].trim(), row[1].trim())
        }
        return value.put("DnsHosts", hosts).toString()
    }
    Column(Modifier.fillMaxSize()) {
        FormColumn(Modifier.weight(1f), bottomPadding = 24.dp) {
            if (jsonEditor) TextField(tr(R.string.routing_json), raw, 10) { raw = it }
            else {
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
                    listOf("rules" to tr(R.string.rules), "dns" to "DNS", "advanced" to tr(R.string.advanced)).forEachIndexed { index, (key, label) ->
                        SegmentedButton(selected = section == key, onClick = { section = key }, enabled = !busy, shape = SegmentedButtonDefaults.itemShape(index, 3)) { Text(label) }
                    }
                }
                when (section) {
                    "rules" -> {
                        ToggleField(tr(R.string.proxy_unmatched_traffic), draft.string("GlobalProxy", "true") == "true", enabled = !busy) { set("GlobalProxy", it.toString()) }
                        listOf(tr(R.string.direct), tr(R.string.proxy), tr(R.string.block)).forEach { action ->
                            HorizontalDivider()
                            Text(action, style = MaterialTheme.typography.titleMedium)
                            TextField(tr(R.string.domains), inputs[action + "Sites"] ?: "", 3) { inputs[action + "Sites"] = it }
                            TextField(tr(R.string.ip_addresses_and_networks), inputs[action + "Ip"] ?: "", 3) { inputs[action + "Ip"] = it }
                            Text(tr(R.string.one_target_per_line_domains_support), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                    "dns" -> {
                        ToggleField(tr(R.string.keep_domain_identity_with_fake_dns), draft.string("FakeDNS") == "true", enabled = !busy) { set("FakeDNS", it.toString()) }
                        for (prefix in listOf("Remote", "Domestic")) {
                            HorizontalDivider()
                            Text(if (prefix == "Remote") tr(R.string.remote_dns) else tr(R.string.direct_dns), style = MaterialTheme.typography.titleMedium)
                            ChoiceField(tr(R.string.resolver_type), draft.string("${prefix}DNSType", "DoU"), listOf("DoH", "DoU"), listOf(tr(R.string.dns_over_https), "UDP"), enabled = !busy) { set("${prefix}DNSType", it) }
                            if (draft.string("${prefix}DNSType") == "DoH") TextField(tr(R.string.https_url), draft.string("${prefix}DNSDomain")) { set("${prefix}DNSDomain", it) }
                            TextField(tr(R.string.resolver_or_bootstrap_ip), draft.string("${prefix}DNSIP")) { set("${prefix}DNSIP", it) }
                        }
                        HorizontalDivider()
                        ToggleField(tr(R.string.choose_direct_dns_by_domain), draft.has("DomesticDNSDomains"), enabled = !busy) { explicit ->
                            encoded = draft.copy().apply { if (explicit) put("DomesticDNSDomains", JSONArray()) else remove("DomesticDNSDomains") }.toString()
                        }
                        if (draft.has("DomesticDNSDomains")) TextField(tr(R.string.domains_using_direct_dns), inputs["DomesticDNSDomains"] ?: "", 3) { inputs["DomesticDNSDomains"] = it }
                        HorizontalDivider()
                        Text(tr(R.string.static_dns_hosts), style = MaterialTheme.typography.titleMedium)
                        hostRows.forEachIndexed { index, row ->
                            TextField(tr(R.string.hostname), row.getOrElse(0) { "" }) { updateHost(index, 0, it) }
                            TextField(tr(R.string.ipv4_or_ipv6_address), row.getOrElse(1) { "" }) { updateHost(index, 1, it) }
                            TextButton({ inputs["DnsHosts"] = hostRows.filterIndexed { at, _ -> at != index }.joinToString("\n") { it.joinToString("=") } }, enabled = !busy) { Text(tr(R.string.remove_host), color = MaterialTheme.colorScheme.error) }
                        }
                        TextButton({ inputs["DnsHosts"] = (hostRows.map { it.joinToString("=") } + "=").joinToString("\n") }, enabled = !busy, modifier = Modifier.heightIn(min = 48.dp)) { RouteIcon("add", color = MaterialTheme.colorScheme.primary); Spacer(Modifier.width(8.dp)); Text(tr(R.string.add_dns_host)) }
                    }
                    else -> {
                        TextField(tr(R.string.profile_name), draft.string("Name")) { set("Name", it) }
                        val orders = listOf("block-direct-proxy", "block-proxy-direct", "direct-block-proxy", "direct-proxy-block", "proxy-block-direct", "proxy-direct-block")
                        ChoiceField(tr(R.string.rule_order), draft.string("RouteOrder", "block-direct-proxy"), orders, orders.map { it.split('-').joinToString(" → ") { word -> word.replaceFirstChar { letter -> letter.uppercase() } } }, enabled = !busy) { set("RouteOrder", it) }
                        ChoiceField(tr(R.string.resolve_domains_for_routing), draft.string("DomainStrategy", "AsIs"), listOf("AsIs", "IPIfNonMatch", "IPOnDemand"), listOf(tr(R.string.keep_names), tr(R.string.if_no_match), tr(R.string.when_needed)), enabled = !busy) { set("DomainStrategy", it) }
                        ToggleField(tr(R.string.reduce_routing_data_size), draft.string("UseChunkFiles") == "true", enabled = !busy) { set("UseChunkFiles", it.toString()) }
                        TextField(tr(R.string.geoip_url), draft.string("Geoipurl")) { set("Geoipurl", it) }
                        TextField(tr(R.string.geosite_url), draft.string("Geositeurl")) { set("Geositeurl", it) }
                        HorizontalDivider()
                        Text(tr(R.string.managed_domain_lists), style = MaterialTheme.typography.titleMedium)
                        val sources = draft.objects("ManagedSources")
                        sources.forEachIndexed { index, source ->
                            key(source.string("id")) {
                                fun update(key: String, value: String) { val items = sources.map { it.copy() }; items[index].put(key, value); set("ManagedSources", JSONArray(items)) }
                                TextField(tr(R.string.list_url), source.string("url")) { update("url", it) }
                                ChoiceField(tr(R.string.use_domains_for), source.string("destination"), listOf("block", "direct", "proxy", "dns"), listOf(tr(R.string.block), tr(R.string.direct), tr(R.string.proxy), tr(R.string.direct_dns)), enabled = !busy) { update("destination", it) }
                                ChoiceField(tr(R.string.match), source.string("matchMode"), listOf("exact", "subdomains"), listOf(tr(R.string.exact_domains), tr(R.string.include_subdomains)), enabled = !busy) { update("matchMode", it) }
                                TextButton({ set("ManagedSources", JSONArray(sources.filterIndexed { at, _ -> at != index })) }, enabled = !busy) { Text(tr(R.string.remove_list), color = MaterialTheme.colorScheme.error) }
                                HorizontalDivider()
                            }
                        }
                        TextButton({ set("ManagedSources", JSONArray(sources + obj("id" to newId(), "url" to "", "destination" to "block", "matchMode" to "subdomains"))) }, enabled = !busy && sources.size < 125, modifier = Modifier.heightIn(min = 48.dp)) { RouteIcon("add", color = MaterialTheme.colorScheme.primary); Spacer(Modifier.width(8.dp)); Text(tr(R.string.add_domain_list)) }
                        Text(tr(R.string.use_a_trusted_public_https_source), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
            error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        }
        Surface {
            Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 12.dp)) {
                EditorActions(busy, done, {
                    try { activity.saveReviewed("saveRouting", obj("id" to id, "text" to if (jsonEditor) raw else formContent())) }
                    catch (_: Exception) { error = tr(R.string.enter_a_unique_hostname_and_an) }
                })
            }
        }
    }
}

@Composable fun BackupEditor(restore: Boolean, busy: Boolean, activity: MainActivity, done: () -> Unit) {
    var password by rememberDraft(activity, "backup-password") { "" }; var repeat by rememberDraft(activity, "backup-repeat") { "" }; var error by remember { mutableStateOf<String?>(null) }
    FormColumn {
        Text(if (restore) tr(R.string.restore_replaces_this_device_s_subscriptions) else tr(R.string.the_encrypted_backup_contains_subscriptions_servers))
        OutlinedTextField(password, { password = it }, label = { Text(tr(R.string.backup_password)) }, visualTransformation = PasswordVisualTransformation(), singleLine = true, modifier = Modifier.fillMaxWidth(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
        if (!restore) OutlinedTextField(repeat, { repeat = it }, label = { Text(tr(R.string.repeat_password)) }, visualTransformation = PasswordVisualTransformation(), singleLine = true, modifier = Modifier.fillMaxWidth(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
        Text(tr(R.string.use_at_least_12_characters), style = MaterialTheme.typography.bodySmall)
        error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        EditorActions(busy, done, {
            if (!restore && password != repeat) error = tr(R.string.the_passwords_do_not_match)
            else if (restore) activity.saveReviewed("restore", obj("text" to (activity.interaction.restore ?: ""), "password" to password))
            else activity.run("backup", obj("password" to password)) { password = ""; repeat = ""; activity.save(it.getString("text"), "elarni-backup.rvbackup"); done() }
        }, if (restore) tr(R.string.restore) else tr(R.string.export_backup))
    }
}

@Composable fun SourceOptionsEditor(catalog: Catalog, id: String, busy: Boolean, activity: MainActivity, done: () -> Unit) {
    val source = catalog.sources.firstOrNull { it.string("id") == id }
    if (source == null) { EmptyDetail(); return }
    val options = source.mapObject("fetchOptions")
    val fields = listOf("refreshHours" to tr(R.string.refresh_every_hours_override), "userAgent" to tr(R.string.user_agent), "connectAddress" to tr(R.string.connect_address_override), "httpHost" to tr(R.string.http_host_override), "fragmentLength" to tr(R.string.tls_fragment_length), "fragmentInterval" to tr(R.string.tls_fragment_interval))
    val values = remember(id, activity.interaction) { activity.interaction.fields("source-options-$id") { fields.associate { it.first to options.string(it.first) } } }
    var fallback by rememberDraft(activity, "source-fallback-$id") { source.strings("fallbackHosts").joinToString("\n") }
    FormColumn {
        val provider = source.mapObject("metadata").optInt("updateIntervalHours")
        fields.forEach { (key, label) ->
            TextField(label, values[key] ?: "") { values[key] = it }
            if (key == "refreshHours") Text(if (provider > 0) tr(R.string.leave_empty_to_follow_the_provider, provider) else tr(R.string.leave_empty_to_follow_the_app, catalog.settings.getInt("subscriptionAutoUpdateHours")),
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        TextField(tr(R.string.fallback_hosts_one_per_line), fallback, 3) { fallback = it }
        EditorActions(busy, done, { val value = JSONObject(); fields.forEach { if (!values[it.first].isNullOrEmpty()) value.put(it.first, values[it.first]) }; activity.saveReviewed("sourceOptions", obj("id" to id, "options" to value, "fallbackHosts" to JSONArray(lines(fallback)))) })
    }
}

@Composable fun AutomationEditor(catalog: Catalog, busy: Boolean, activity: MainActivity, done: () -> Unit) {
    val saved = catalog.data.optJSONObject("automation") ?: Automation.defaults()
    var enabled by rememberSaveable { mutableStateOf(saved.optBoolean("enabled")) }
    var policy by rememberSaveable { mutableStateOf(saved.string("policy", "fixed")) }
    var selected by rememberSaveable { mutableStateOf(saved.strings("nodeIDs").ifEmpty { listOf(catalog.selected).filter(String::isNotEmpty) }) }
    var targetsJSON by rememberDraft(activity, "automation-targets") { JSONArray(saved.objects("targets")).toString() }
    val targets = remember(targetsJSON) { JSONArray(targetsJSON).objects().map { it.toString() } }
    fun setTargets(values: List<String>) { targetsJSON = JSONArray(values.map(::JSONObject)).toString() }
    val locations = remember { ServerLocations(activity) }
    FormColumn {
        ToggleField(tr(R.string.enable_automatic_selection), enabled) { enabled = it }
        ChoiceField(tr(R.string.policy), policy, listOf("fixed", "orderedFallback", "lowestLatency"), listOf(tr(R.string.keep_selected_server), tr(R.string.ordered_fallback), tr(R.string.lowest_latency))) { policy = it }
        Text(tr(R.string.allowed_servers_listed_in_fallback_order), style = MaterialTheme.typography.titleMedium)
        Text(tr(R.string.servers_may_come_from_any_subscription), style = MaterialTheme.typography.bodySmall)
        val available = catalog.nodes.filter { it.string("format") == "xrayProfile" }
        // A provider refresh can remove a chosen server, which then has no row to clear it with.
        val chosen = selected.filter { id -> available.any { it.string("id") == id } }
        chosen.forEach { id ->
            Row(Modifier.toggleable(true, role = Role.Checkbox) { selected = chosen - id }, verticalAlignment = Alignment.CenterVertically) {
                Checkbox(true, null)
                Column(Modifier.weight(1f)) {
                    Text(catalog.node(id).string("name"))
                    Text(catalog.sourceFor(id).string("name"), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                if (chosen.indexOf(id) > 0) TextButton({ val items = chosen.toMutableList(); val index = items.indexOf(id); items[index] = items[index-1]; items[index-1] = id; selected = items }) { Text(tr(R.string.up)) }
            }
        }
        catalog.sources.forEach { source ->
            val rest = source.objects("nodes").filter { it.string("format") == "xrayProfile" && it.string("id") !in chosen }
            if (rest.isNotEmpty()) Text(source.string("name"), style = MaterialTheme.typography.labelLarge, modifier = Modifier.padding(top = 8.dp))
            rest.forEach { node ->
                Row(Modifier.toggleable(false, role = Role.Checkbox) { selected = chosen + node.string("id") }, verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(false, null)
                    Text(node.string("name"), Modifier.weight(1f))
                }
            }
        }
        Text(tr(R.string.health_targets), style = MaterialTheme.typography.titleMedium)
        targets.forEachIndexed { index, encoded ->
            val target = JSONObject(encoded)
            fun update(key: String, value: Any) { val items = targets.toMutableList(); items[index] = target.copy().put(key, value).toString(); setTargets(items) }
            TextField(tr(R.string.target_url), target.string("url")) { update("url", it) }
            TextField(tr(R.string.expected_http_status), target.opt("expectedStatus")?.toString() ?: "204") { update("expectedStatus", it.toIntOrNull() ?: it) }
            TextField(tr(R.string.expected_response_body), target.string("expectedBody"), 2) { update("expectedBody", it) }
            TextButton({ setTargets(targets.filterIndexed { i, _ -> i != index }) }) { Text(tr(R.string.remove_target)) }
            HorizontalDivider()
        }
        if (targets.size < 2) TextButton({ setTargets(targets + obj("id" to newId(), "url" to "", "expectedStatus" to 204, "expectedBody" to "").toString()) }) { Text(tr(R.string.add_target)) }
        EditorActions(busy, done, {
            val source = catalog.sources.firstOrNull { it.objects("nodes").any { n -> n.string("id") == catalog.selected } }?.string("id") ?: ""
            val russian = chosen.filter { locations.russianEntry(catalog.node(it).string("name")) }
            activity.saveReviewed("automation", obj("configuration" to obj("schemaVersion" to 1, "enabled" to enabled, "policy" to policy, "subscriptionID" to source,
                "nodeIDs" to JSONArray(chosen), "russianEntryNodeIDs" to JSONArray(russian), "targets" to JSONArray(targets.map(::JSONObject)))))
        })
    }
}

@Composable fun PingEditor(id: String, state: AppState, activity: MainActivity, sourceId: String = "") {
    val saved = Catalog(state.catalog).settings
    var protocol by rememberSaveable { mutableStateOf(saved.string("probeMode", "proxy")) }; var url by rememberSaveable { mutableStateOf(saved.string("probeURL", "https://www.gstatic.com/generate_204")) }
    var timeout by rememberSaveable { mutableStateOf(saved.optInt("probeTimeout", 5).toString()) }; var method by rememberSaveable { mutableStateOf(saved.string("probeMethod", "GET")) }
    var mode by rememberSaveable { mutableStateOf(saved.string("probeVariant", "default")) }
    val clock by rememberClock()
    var expected by rememberSaveable { mutableStateOf(saved.optInt("probeExpectedStatus", 204).toString()) }; var body by rememberDraft(activity, "ping-body-$id") { saved.string("probeExpectedBody") }
    FormColumn {
        ChoiceField(tr(R.string.test_method), protocol, listOf("proxy", "activeProxy", "tcp", "icmp"), listOf(tr(R.string.proxy), tr(R.string.active_proxy_2), tr(R.string.direct_tcp_2), tr(R.string.direct_icmp_2))) { protocol = it }
        TextField(tr(R.string.timeout_in_seconds_1_15), timeout) { timeout = it }
        if (protocol in listOf("proxy", "activeProxy")) {
            TextField(tr(R.string.test_url), url) { url = it }
            ChoiceField(tr(R.string.http_method), method, listOf("HEAD", "GET")) { method = it }
            ChoiceField(tr(R.string.probe_mode), mode, listOf("default", "double", "keepalive"), listOf(tr(R.string.single_request), tr(R.string.double_request), "Keep-alive")) { mode = it }
            TextField(tr(R.string.expected_http_status), expected) { expected = it }
            TextField(tr(R.string.expected_response_body), body, 2) { body = it }
        }
        Button({
            // The core requires both expectations (an empty body expects an empty response) and admits 1–15 s.
            activity.run("ping", obj("id" to id, "sourceId" to sourceId, "protocol" to protocol, "timeout" to (timeout.toIntOrNull()?.coerceIn(1, 15) ?: 0), "url" to url,
                "method" to method, "mode" to mode, "expectedStatus" to (expected.toIntOrNull() ?: 0), "expectedBody" to body))
        }, enabled = !state.busy) { Text(tr(R.string.run_test)) }
        val catalog = Catalog(state.catalog)
        val scopedIds = catalog.sources.firstOrNull { it.string("id") == sourceId }?.objects("nodes")?.map { it.string("id") }?.toSet() ?: emptySet()
        state.pings.filterKeys { (id.isEmpty() || it == id) && (sourceId.isEmpty() || it in scopedIds) }.forEach { (key, result) ->
            val node = catalog.nodes.firstOrNull { it.string("id") == key }
            Text("${node?.string("name") ?: tr(R.string.server_word)}: ${if (result.string("status") == "success") tr(R.string.ms_value, result.optLong("latencyMs")) else errorMessage(result.string("error"))}")
            Text("${pingScope(result)} · ${date(result.optDouble("timestamp"))}${if (node == null || !pingFresh(node, result, clock)) " · " + tr(R.string.outdated) else ""}", style = MaterialTheme.typography.bodySmall)
        }
    }
}
