/*************************************************************************
 * ModernUO                                                              *
 * Copyright 2019-2026 - ModernUO Development Team                       *
 * Email: hi@modernuo.com                                                *
 * File: Map.WideView.cs                                                 *
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
using Server.Network;

namespace Server;

/// <summary>
/// Zuluhotel: one area of one map where clients see farther than <see cref="Core.GlobalUpdateRange"/> (the Colosseum
/// island, view 36). The shard sets <see cref="Map"/>, <see cref="Bounds"/> and <see cref="Range"/> in its Configure;
/// with <see cref="Map"/> null every check below is the stock ModernUO range.
/// <para>
/// The rule is pairwise and symmetric: a viewer and a source see each other at <see cref="Range"/> only when BOTH stand
/// in the area, otherwise at the stock range. A one-sided rule leaves frozen objects on a client (the viewer's own
/// moves send a far object, the object's moves never reach the viewer). Only packet sends use it: combat, use and
/// targeting checks (<see cref="Utility.InUpdateRange(Point3D, Point3D)"/>) stay at the stock range.
/// </para>
/// </summary>
public static class WideView
{
    public static Map Map { get; set; }

    public static Rectangle2D Bounds { get; set; }

    public static int Range { get; set; } = 36;

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static bool IsWide(Map map, Point3D p) => IsWide(map, p.m_X, p.m_Y);

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static bool IsWide(Map map, int x, int y) => map != null && map == Map && Bounds.Contains(x, y);

    /// <summary>Radius to enumerate clients or objects around <paramref name="p"/>: the wide range in the area.</summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static int RangeAt(Map map, Point3D p, int normal) => IsWide(map, p) ? Math.Max(Range, normal) : normal;

    /// <summary>Range between two points: the wide range only when both are in the area.</summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static int Pair(Map map, Point3D a, Point3D b, int normal) =>
        IsWide(map, a) && IsWide(map, b) ? Math.Max(Range, normal) : normal;

    /// <summary>Stock <see cref="Utility.InUpdateRange(Point3D, Point3D)"/>, widened for a pair in the area.</summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static bool InView(Map map, Point3D a, Point3D b) =>
        Utility.InRange(a, b, Pair(map, a, b, Core.GlobalUpdateRange));

    /// <summary>Stock broadcast reach (<see cref="Core.GlobalMaxUpdateRange"/>), widened for a pair in the area.</summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static bool InBroadcast(Map map, Point3D a, Point3D b) =>
        Utility.InRange(a, b, Pair(map, a, b, Core.GlobalMaxUpdateRange));
}

public partial class Map
{
    /// <summary>
    /// <see cref="GetClientsInRange(Point3D)"/> that also reaches the clients seeing <paramref name="p"/> through
    /// <see cref="WideView"/>. Outside the area it is exactly the stock enumeration.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public ClientViewEnumerable GetClientsInView(Point3D p) => new(this, p);

    public ref struct ClientViewEnumerable
    {
        private readonly Map _map;
        private readonly Point3D _source;

        public ClientViewEnumerable(Map map, Point3D source)
        {
            _map = map;
            _source = source;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public ClientViewEnumerator GetEnumerator() => new(_map, _source);
    }

    public ref struct ClientViewEnumerator
    {
        private readonly Map _map;
        private readonly Point3D _source;
        private readonly bool _wide;
        private ClientBoundsEnumerator _inner;

        public ClientViewEnumerator(Map map, Point3D source)
        {
            _map = map;
            _source = source;
            _wide = WideView.IsWide(map, source);
            var range = _wide ? Math.Max(WideView.Range, Core.GlobalMaxUpdateRange) : Core.GlobalMaxUpdateRange;
            _inner = map == null ? default : map.GetClientsInRange(source, range).GetEnumerator();
        }

        public bool MoveNext()
        {
            if (_map == null)
            {
                return false;
            }

            while (_inner.MoveNext())
            {
                // outside the area nothing is filtered: the stock enumeration
                if (!_wide || WideView.InBroadcast(_map, _inner.Current.Mobile.Location, _source))
                {
                    return true;
                }
            }

            return false;
        }

        public NetState Current
        {
            [MethodImpl(MethodImplOptions.AggressiveInlining)]
            get => _inner.Current;
        }
    }
}
