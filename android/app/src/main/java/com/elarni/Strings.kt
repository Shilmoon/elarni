package com.elarni

// Strings in the app's language (res/values-ru and the per-app language setting), from composables and services alike.
// Call them where the text is shown, never from a top-level or object val, which would keep the first language.

fun tr(id: Int, vararg args: Any?): String = ElarniApplication.instance.resources.run {
    if (args.isEmpty()) getString(id) else getString(id, *args)
}

/** The plural form for [count]; [args] replace the count as the format arguments when the text needs more than it. */
fun trPlural(id: Int, count: Int, vararg args: Any?): String =
    ElarniApplication.instance.resources.getQuantityString(id, count, *(if (args.isEmpty()) arrayOf<Any?>(count) else args))
