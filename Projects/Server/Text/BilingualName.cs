/*************************************************************************
 * ModernUO                                                              *
 * Copyright 2019-2026 - ModernUO Development Team                       *
 * Email: hi@modernuo.com                                                *
 * File: BilingualName.cs                                                *
 *                                                                       *
 * This program is free software: you can redistribute it and/or modify  *
 * it under the terms of the GNU General Public License as published by  *
 * the Free Software Foundation, either version 3 of the License, or     *
 * (at your option) any later version.                                   *
 *                                                                       *
 * You should have received a copy of the GNU General Public License     *
 * along with this program.  If not, see <http://www.gnu.org/licenses/>. *
 *************************************************************************/

using System;
using System.Runtime.CompilerServices;

namespace Server.Text;

/// <summary>
/// Helper for the bilingual "русский|english" name convention used by ZuluContent.
///
/// Many legacy UO protocol packets carry a fixed-length Latin-1 (ISO-8859-1) name
/// slot (0x98 mob name, 0x11 healthbar, 0x88 paperdoll title, 0x6F trade, 0xC1
/// localized-message speaker, etc.). Latin-1 cannot encode Cyrillic — every U+04xx
/// codepoint becomes '?'. To keep Russian players from seeing "???" in these slots
/// the shard stores names bilingually as "русский|english" and we write the English
/// half into Latin-1 slots while the matching Unicode-capable channel (OPL tooltip,
/// 0xAE Unicode speech body, gump labels) carries the locale-appropriate half.
///
/// This helper is the single source of truth for that split. Apply at every site
/// that writes a name into a Latin-1 protocol slot.
/// </summary>
public static class BilingualName
{
    /// <summary>
    /// Returns the ASCII-safe (English) half of a bilingual "русский|english" name.
    /// For non-bilingual inputs (no pipe) returns the input unchanged.
    /// Null/empty inputs return "" so callers don't have to null-check.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static string AsciiSafe(string name)
    {
        if (string.IsNullOrEmpty(name))
        {
            return "";
        }

        var pipe = name.IndexOf('|');
        return pipe >= 0 ? name[(pipe + 1)..] : name;
    }

    /// <summary>
    /// ReadOnlySpan&lt;char&gt; overload for hot paths that already work with spans.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static ReadOnlySpan<char> AsciiSafe(ReadOnlySpan<char> name)
    {
        if (name.IsEmpty)
        {
            return ReadOnlySpan<char>.Empty;
        }

        var pipe = name.IndexOf('|');
        return pipe >= 0 ? name[(pipe + 1)..] : name;
    }
}
