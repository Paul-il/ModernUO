/*************************************************************************
 * ModernUO                                                              *
 * Copyright 2019-2026 - ModernUO Development Team                       *
 * Email: hi@modernuo.com                                                *
 * File: OutgoingMenuPackets.cs                                          *
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
using System.Buffers;
using System.IO;
using Server.Menus.ItemLists;
using Server.Menus.Questions;
using Server.Text;

namespace Server.Network;

[Flags]
public enum CMEFlags
{
    None = 0x00,
    Disabled = 0x01,
    Arrow = 0x02,
    Highlighted = 0x04,
    Colored = 0x20
}

public static class OutgoingMenuPackets
{
    public static void SendDisplayItemListMenu(this NetState ns, ItemListMenu menu)
    {
        if (ns == null || menu == null)
        {
            return;
        }

        // Menu text is Latin-1 (length-prefixed); strip bilingual to English half BEFORE measuring length.
        var question = BilingualName.AsciiSafe(menu.Question?.Trim());
        var questionLength = question.Length;

        var entries = menu.Entries;
        int entriesLength = (byte)entries.Length;

        var maxLength = 11 + questionLength;
        for (var i = 0; i < entriesLength; i++)
        {
            maxLength += 5 + entries[i].Name?.Length ?? 0; // could be trimmed
        }

        var writer = new SpanWriter(stackalloc byte[maxLength]);
        writer.Write((byte)0x7C); // Packet ID
        writer.Seek(2, SeekOrigin.Current);
        writer.Write(menu.Serial);
        writer.Write((ushort)0);

        writer.Write((byte)questionLength);

        if (questionLength > 0)
        {
            writer.WriteLatin1(question);
        }

        writer.Write((byte)entriesLength);

        for (var i = 0; i < entriesLength; ++i)
        {
            var e = entries[i];

            writer.Write((ushort)e.ItemID);
            writer.Write((short)e.Hue);

            var name = BilingualName.AsciiSafe(e.Name?.Trim());

            if (name.Length == 0)
            {
                writer.Write((byte)0);
            }
            else
            {
                writer.Write((byte)name.Length);
                writer.WriteLatin1(name);
            }
        }

        writer.WritePacketLength();
        ns.Send(writer.Span);
    }

    public static void SendDisplayQuestionMenu(this NetState ns, QuestionMenu menu)
    {
        if (ns == null || menu == null)
        {
            return;
        }

        // Menu text is Latin-1 (length-prefixed); strip bilingual to English half BEFORE measuring length.
        var question = BilingualName.AsciiSafe(menu.Question?.Trim());
        var questionLength = question.Length;

        var answers = menu.Answers;
        int answersLength = (byte)answers.Length;

        var maxLength = 11 + questionLength;
        for (var i = 0; i < answersLength; i++)
        {
            maxLength += 5 + answers[i]?.Length ?? 0; // could be trimmed
        }

        var writer = new SpanWriter(stackalloc byte[maxLength]);
        writer.Write((byte)0x7C); // Packet ID
        writer.Seek(2, SeekOrigin.Current);
        writer.Write(menu.Serial);
        writer.Write((ushort)0);
        writer.Write((byte)questionLength);

        if (questionLength > 0)
        {
            writer.WriteLatin1(question);
        }

        writer.Write((byte)answersLength);

        for (var i = 0; i < answersLength; ++i)
        {
            writer.Write(0);

            var answer = BilingualName.AsciiSafe(answers[i]?.Trim());

            if (answer.Length == 0)
            {
                writer.Write((byte)0);
            }
            else
            {
                writer.Write((byte)answer.Length);
                writer.WriteLatin1(answer);
            }
        }

        writer.WritePacketLength();
        ns.Send(writer.Span);
    }
}
