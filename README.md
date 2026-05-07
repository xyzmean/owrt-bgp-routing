# OpenWrt BGP Routing Setup

Интерактивный скрипт для настройки выборочной BGP-маршрутизации на роутерах с OpenWrt через WireGuard/AmneziaWG туннель и BIRD2.

## Что делает скрипт

Скрипт автоматически настраивает схему, при которой трафик из локальной сети направляется через VPN-туннель только для тех IP-адресов, которые анонсируются через BGP. Остальной трафик идёт через обычного провайдера.

Архитектура:

```
[LAN клиенты] → ip rule (by source) → routing table → BIRD2 (BGP) → через WG туннель
               ↓ (default)
               обычный WAN
```

### Пошагово:

1. **Определяет сеть** — автоматически находит WAN, LAN, туннель
2. **Настраивает BGP-пиринг** — один или несколько пиров, с опциональной фильтрацией по BGP communities
3. **Устанавливает BIRD2** — через `opkg` или `apk`
4. **Генерирует `/etc/bird.conf`** — статические маршруты до пиров через WAN, BGP-сессии, экспорт BGP-маршрутов в kernel routing table
5. **Настраивает `rc.local`** — добавляет маршрут в туннель и ip rule при загрузке
6. **Создаёт hotplug** — при поднятии/падении туннеля автоматически восстанавливает или сбрасывает таблицу маршрутизации
7. **Fallback** (опционально) — cron-задача, которая сбрасывает BGP-маршруты если туннель недоступен
8. **Sysctl** (опционально) — увеличивает буферы сети для лучшей производительности

## Использование

Загрузите и запустите на роутере:

```bash
wget -O /tmp/bgp-setup.sh <URL> && sh /tmp/bgp-setup.sh
```

Скрипт задаст вопросы в интерактивном режиме:

- Интерфейс туннеля (WireGuard/AmneziaWG)
- IP-адрес маршрутизатора в туннеле и шлюз
- Номер routing table и приоритет ip rule
- Local AS
- BGP-пиры: имя, IP, AS, опционально communities
- Включить ли fallback и настройку sysctl

### Минимальные требования

- OpenWrt (или другой дистрибутив с `opkg`/`apk`)
- Работающий WireGuard или AmneziaWG туннель
- BGP-сервер, анонсирующий маршруты (например, [bgp_block_server](https://github.com/xyzmean/bgp_block_server))

## Пример сессии

```
═══ Auto-detecting network ═══
  WAN:     eth1 gw 192.168.1.1
  LAN:     192.168.100.1/24

═══ WireGuard / Tunnel ═══
  Detected tunnel: wg0 (10.8.0.2/24)
  Router tunnel IP: 10.8.0.2/24
  Tunnel gateway: 10.8.0.1
  Kernel routing table: 100
  ip rule priority: 1000
  Local AS number: 65433

═══ BGP Peers ═══
  peer1: 5.187.45.110 AS65200

═══ Summary ═══
  Router ID:  192.168.100.1
  Tunnel:     wg0 (10.8.0.2) gw 10.8.0.1
  Table:      100 priority 1000
  LAN → BGP:  192.168.100.0/24
  Local AS:   65433
  BGP peers:  1
```

## Что и где настраивается

| Компонент | Файл |
|-----------|------|
| BIRD2 конфигурация | `/etc/bird.conf` |
| Маршруты и правила при загрузке | `/etc/rc.local` (между маркерами `# BEGIN bgp-setup` / `# END bgp-setup`) |
| Hotplug (туннель up/down) | `/etc/hotplug.d/iface/90-bgp-routing` |
| Fallback cron | `/usr/local/bin/wg-fallback.sh` + crontab |

## Повторный запуск

Безопасно запускать повторно — старые настройки между маркерами `# BEGIN bgp-setup` / `# END bgp-setup` перезаписываются. Предыдущий `bird.conf` сохраняется как `/etc/bird.conf.bak.bgp-setup`.

## Связанные проекты

- [bgp_block_server](https://github.com/xyzmean/bgp_block_server) — BGP-сервер для анонса маршрутов популярных сервисов

## Лицензия

MIT
