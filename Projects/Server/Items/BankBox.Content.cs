/* Автор: Paul Gordon */
using System;
using System.Collections.Generic;
using Server.Network;

namespace Server.Items;

public partial class BankBox
{
    private const int ImmediateContentLimit = 1024;
    private Dictionary<(NetState State, Container Container), ContentView> _contentViews;

    private static BankBox ContainingBank(Container container)
    {
        for (Item item = container; item != null; item = item.Parent as Item)
        {
            if (item is BankBox bank)
            {
                return bank;
            }
        }
        return null;
    }

    internal static bool StreamsContent(Container container) =>
        container.Items.Count > ImmediateContentLimit && ContainingBank(container) != null;

    internal static bool TrySendNestedContent(Container container, NetState state)
    {
        var bank = ContainingBank(container);
        if (bank == null || container.Items.Count <= ImmediateContentLimit)
        {
            bank?.CancelContentView(state, container);
            return false;
        }
        bank.SendContentTo(state, container);
        return true;
    }

    public override void DisplayTo(Mobile to)
    {
        if (Items.Count <= ImmediateContentLimit)
        {
            CancelContentView(to.NetState, this);
            base.DisplayTo(to);
            return;
        }

        ProcessOpeners(to);
        var state = to.NetState;
        if (state != null)
        {
            state.SendDisplayContainer(Serial, GumpID);
            SendContentTo(state);
        }
    }

    public override void SendContentTo(NetState state) => SendContentTo(state, this);

    private void SendContentTo(NetState state, Container container)
    {
        CancelContentView(state, container);
        if (state.CannotSendPackets())
        {
            return;
        }

        if (container.Items.Count <= ImmediateContentLimit)
        {
            state.SendContainerContent(state.Mobile, container);
            return;
        }

        var view = new ContentView(this, container, state);
        (_contentViews ??= new())[(state, container)] = view;
        view.SendNext();
    }

    private void CancelContentView(NetState state, Container container)
    {
        if (state != null && _contentViews != null && _contentViews.Remove((state, container), out var view))
        {
            view.Cancel();
        }
    }

    private void CancelContentViews()
    {
        if (_contentViews == null)
        {
            return;
        }

        foreach (var view in _contentViews.Values)
        {
            view.Cancel();
        }
        _contentViews.Clear();
    }

    public override void OnAfterDelete()
    {
        CancelContentViews();
        base.OnAfterDelete();
    }

    // Только состояние отправки. Предметы не перемещаются, сериализация банка не меняется.
    private sealed class ContentView
    {
        private readonly BankBox _bank;
        private readonly Container _container;
        private readonly NetState _state;
        private readonly Mobile _viewer;
        private Item[] _items;
        private int _index;
        private bool _started;
        private TimerExecutionToken _token;

        public ContentView(BankBox bank, Container container, NetState state)
        {
            _bank = bank;
            _container = container;
            _state = state;
            _viewer = state.Mobile;
            _items = container.Items.ToArray();
        }

        public void Cancel()
        {
            _token.Cancel();
            _items = Array.Empty<Item>();
        }

        private bool CanSend(Item item) =>
            !item.Deleted && item.Parent == _container && _viewer.CanSee(item);

        public void SendNext()
        {
            if (_bank.Deleted || _container.Deleted || _viewer == null || _viewer.Deleted || _viewer.NetState != _state ||
                _state.CannotSendPackets() || !_bank.IsAccessibleTo(_viewer) || !_container.IsAccessibleTo(_viewer) ||
                ContainingBank(_container) != _bank)
            {
                _bank.CancelContentView(_state, _container);
                return;
            }

            // Оставляем запас для обычных пакетов и расширения при сжатии. Медленный клиент
            // получает следующую порцию после освобождения буфера, без отключения и потери списка.
            if (_state.GetSendBuffer(out var buffer) && buffer.Length >= 32768)
            {
                if (!_started)
                {
                    // Пока буфер был занят, состав банка мог измениться.
                    _items = _container.Items.ToArray();
                    _index = 0;
                    while (_index < _items.Length && !CanSend(_items[_index]))
                    {
                        _index++;
                    }

                    // Только первый пакет 0x3C очищает окно. Остальные предметы идут через 0x25.
                    _state.SendContainerContent(_viewer, _container, maximumItems: 1);
                    _started = true;
                    if (_index < _items.Length)
                    {
                        if (ObjectPropertyList.Enabled)
                        {
                            _state.SendOPLInfo(_items[_index]);
                        }
                        _index++;
                    }
                }

                var end = Math.Min(_items.Length, _index + 256);
                while (_index < end)
                {
                    var item = _items[_index++];
                    if (CanSend(item))
                    {
                        _state.SendContainerContentUpdate(item);
                        if (ObjectPropertyList.Enabled)
                        {
                            _state.SendOPLInfo(item);
                        }
                    }
                }
            }

            if (_index >= _items.Length)
            {
                _bank.CancelContentView(_state, _container);
            }
            else
            {
                Timer.StartTimer(TimeSpan.FromMilliseconds(25), SendNext, out _token);
            }
        }
    }
}
