// ---------------------------------------------------------------------------
// WHIP racing tablet
// ---------------------------------------------------------------------------
// Runs inside the racing page itself -- no frame -- so its requests go out
// exactly like the page's own, which reach the game on GTA V Enhanced. It
// talks to the callbacks in client/tablet.lua and listens for the app events
// that file sends ({ event = 'sendAppEvent', app, action, payload }).
//
// Answers are read defensively: an empty Lua table can arrive as {} or [],
// and a keyed table (the players in a race) as an object, so every list is
// read through list().
// ---------------------------------------------------------------------------

(() => {
    'use strict';

    const RESOURCE = window.GetParentResourceName ? GetParentResourceName() : 'whip-racing';
    const inGame = !!window.invokeNative;
    const root = document.getElementById('whipTablet');
    if (!root) return;

    const CLASS_COLOURS = { S: 'var(--ht-class-s)', A: 'var(--ht-class-a)', B: 'var(--ht-class-b)', C: 'var(--ht-class-c)', D: 'var(--ht-class-d)' };
    const STATUS = { 0: 'Waiting', 1: 'Racing', 2: 'Finished', 3: 'Cancelled' };
    const MODE = { ranked: 'Ranked', unranked: 'Unranked', 'pink-slip': 'Pink slip' };

    const state = {
        open: false,
        me: { stateId: '0', name: '' },
        admin: false,
        canRank: false,
        ghostDefault: 2,
        ghostModes: ['Off', '1 Minute', '2 Minutes', '5 Minutes', 'Permanent'],
        classes: ['S', 'A', 'B', 'C', 'D'],
        options: { buyin: true, buyinMax: 100000, maxLaps: 20 },
        settings: {},
        currentRace: null,
        raceActive: false,
        editTrack: null,
        screen: 'home',
        params: {},
        history: [],
        token: 0,       // bumps on every screen change, so a late answer cannot draw over a newer screen
    };

    // ------------------------------------------------------------- Helpers

    async function post(name, data) {
        if (!inGame) return mock(name, data || {});
        try {
            const response = await fetch(`https://${RESOURCE}/${name}`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json; charset=UTF-8' },
                body: JSON.stringify(data || {}),
            });
            if (!response.ok) return null;
            const text = await response.text();
            return text ? JSON.parse(text) : null;
        } catch (error) {
            return null;
        }
    }

    const list = (value) => {
        if (Array.isArray(value)) return value;
        if (value && typeof value === 'object') return Object.values(value);
        return [];
    };

    function el(tag, className, text) {
        const node = document.createElement(tag);
        if (className) node.className = className;
        if (text !== undefined && text !== null) node.textContent = text;
        return node;
    }

    function icon(id) {
        const ns = 'http://www.w3.org/2000/svg';
        const svg = document.createElementNS(ns, 'svg');
        svg.setAttribute('class', 'ic');
        svg.setAttribute('viewBox', '0 0 24 24');
        const use = document.createElementNS(ns, 'use');
        use.setAttribute('href', '#' + id);
        svg.append(use);
        return svg;
    }

    function button(label, className, onClick, iconId) {
        const b = el('button', 'ht-btn' + (className ? ' ' + className : ''));
        b.type = 'button';
        if (iconId) b.append(icon(iconId));
        b.append(document.createTextNode(label));
        if (onClick) b.addEventListener('click', onClick);
        return b;
    }

    const fmtNum = (n) => Math.floor(Number(n) || 0).toLocaleString('en-US');

    function fmtTime(ms) {
        ms = Number(ms);
        if (!ms || ms < 0) return '--:--.---';
        const m = Math.floor(ms / 60000);
        const s = Math.floor((ms % 60000) / 1000);
        const r = Math.floor(ms % 1000);
        return `${m}:${String(s).padStart(2, '0')}.${String(r).padStart(3, '0')}`;
    }

    function fmtDuration(ms) {
        const minutes = Math.floor((Number(ms) || 0) / 60000);
        if (minutes < 60) return `${minutes} min`;
        return `${Math.floor(minutes / 60)} h ${minutes % 60} min`;
    }

    function classBadge(cls) {
        const b = el('span', 'ht-class', cls || '?');
        b.style.setProperty('--c', CLASS_COLOURS[cls] || 'var(--ht-faint)');
        return b;
    }

    function tag(text, kind) { return el('span', 'ht-tag' + (kind ? ' ' + kind : ''), text); }

    function posBadge(position) {
        const p = Number(position) || 0;
        return el('span', 'ht-pos' + (p >= 1 && p <= 3 ? ' p' + p : ''), p ? String(p) : '-');
    }

    function section(title, linkLabel, onLink) {
        const wrap = el('div', 'ht-section');
        const head = el('div', 'ht-section-head');
        head.append(el('h2', '', title));
        if (linkLabel) {
            const link = el('button', 'link', linkLabel);
            link.type = 'button';
            link.addEventListener('click', onLink);
            head.append(link);
        }
        wrap.append(head);
        return wrap;
    }

    function empty(text) { return el('div', 'ht-empty', text); }
    function loading() { return el('div', 'ht-loading', 'Loading'); }

    let toastTimer;
    function toast(text, bad) {
        if (!text) return;
        const frame = root.querySelector('.ht-frame');
        if (!frame) return;
        frame.querySelector('.ht-toast')?.remove();
        const t = el('div', 'ht-toast' + (bad ? ' bad' : ''), text);
        frame.append(t);
        clearTimeout(toastTimer);
        toastTimer = setTimeout(() => t.remove(), 3500);
    }

    function confirmBox(title, text, confirmLabel, onConfirm) {
        const frame = root.querySelector('.ht-frame');
        const modal = el('div', 'ht-modal');
        const box = el('div', 'box');
        box.append(el('h3', '', title), el('p', '', text));
        const row = el('div', 'ht-row');
        row.append(button(confirmLabel, 'danger', () => { modal.remove(); onConfirm(); }), button('Cancel', '', () => modal.remove()));
        box.append(row);
        modal.append(box);
        modal.addEventListener('click', (e) => { if (e.target === modal) modal.remove(); });
        frame.append(modal);
    }

    function field(label, control) {
        const f = el('label', 'ht-field');
        f.append(el('span', '', label), control);
        return f;
    }

    function input(value, placeholder, type) {
        const i = el('input', 'ht-input');
        i.type = type || 'text';
        if (value !== undefined && value !== null) i.value = value;
        if (placeholder) i.placeholder = placeholder;
        i.spellcheck = false;
        i.autocomplete = 'off';
        return i;
    }

    function select(options, value) {
        const s = el('select', 'ht-select');
        options.forEach(([v, label]) => {
            const o = el('option', '', label);
            o.value = v;
            s.append(o);
        });
        if (value !== undefined) s.value = String(value);
        return s;
    }

    function toggle(label, on, onChange) {
        const t = el('button', 'ht-toggle' + (on ? ' on' : ''));
        t.type = 'button';
        t.append(el('span', 'sw'), document.createTextNode(label));
        t.addEventListener('click', () => {
            const value = !t.classList.contains('on');
            t.classList.toggle('on', value);
            onChange(value);
        });
        return t;
    }

    // -------------------------------------------------------- Navigation

    const NAV = [
        ['home', 'Overview', 'i-map'],
        ['races', 'Race lobbies', 'i-flag'],
        ['tracks', 'Tracks', 'i-route'],
        ['rankings', 'Rankings', 'i-trophy'],
        ['profile', 'My profile', 'i-car'],
        ['settings', 'Settings', 'i-pin'],
        ['admin', 'Admin', 'i-shield'],
    ];

    function go(screen, params, replace) {
        if (!replace && state.screen) state.history.push({ screen: state.screen, params: state.params });
        if (state.history.length > 30) state.history.shift();
        state.screen = screen;
        state.params = params || {};
        render();
    }

    function back() {
        const previous = state.history.pop();
        if (previous) { state.screen = previous.screen; state.params = previous.params; }
        else { state.screen = 'home'; state.params = {}; }
        render();
    }

    function navRoot(screen) {
        state.history = [];
        state.screen = screen;
        state.params = {};
        render();
    }

    // ------------------------------------------------------------- Shell

    function shell() {
        root.replaceChildren();
        const frame = el('div', 'ht-frame');

        const rail = el('aside', 'ht-rail');
        const brand = el('div', 'ht-brand');
        brand.append(el('small', '', 'WHIP'), el('b', '', 'Racing'));
        rail.append(brand);

        const active = ROOT_OF[state.screen] || state.screen;
        NAV.forEach(([id, label, ic]) => {
            if (id === 'admin' && !state.admin) return;
            const b = el('button', 'ht-nav' + (active === id ? ' on' : ''));
            b.type = 'button';
            b.append(icon(ic), document.createTextNode(label));
            if (id === 'races' && state.currentRace) b.append(el('span', 'count', '1'));
            b.addEventListener('click', () => navRoot(id));
            rail.append(b);
        });

        const me = el('div', 'ht-me');
        me.append(el('small', '', 'Signed in as'), el('b', '', state.me.name || 'Racer'));
        if (state.currentRace) {
            const live = el('button', 'live', state.currentRace.status === 1 ? 'Racing now' : 'In a lobby');
            live.type = 'button';
            live.addEventListener('click', () => go('race', { id: state.currentRace.id }));
            me.append(live);
        }
        rail.append(me);

        const main = el('section', 'ht-main');
        const top = el('header', 'ht-top');
        if (state.history.length) {
            const b = el('button', 'ht-back');
            b.type = 'button';
            b.title = 'Back';
            b.textContent = '‹';
            b.style.fontSize = '1.6em';
            b.addEventListener('click', back);
            top.append(b);
        }
        const title = el('div', 'ht-title');
        const t = TITLES[state.screen] || ['', ''];
        title.append(el('small', '', t[0]), el('h1', '', typeof t[1] === 'function' ? t[1]() : t[1]));
        top.append(title);
        const close = el('button', 'ht-close');
        close.type = 'button';
        close.append(el('kbd', '', 'ESC'), document.createTextNode('Close'));
        close.addEventListener('click', closeTablet);
        top.append(close);

        const body = el('div', 'ht-body');
        main.append(top, body);
        frame.append(rail, main);
        root.append(frame);
        return body;
    }

    const ROOT_OF = { race: 'races', raceCreate: 'races', track: 'tracks', trackEdit: 'tracks', profileOf: 'rankings' };
    const TITLES = {
        home: ['Welcome back', () => state.me.name || 'Overview'],
        races: ['Join or host', 'Race lobbies'],
        race: ['Race lobby', () => state.params.title || 'Race'],
        raceCreate: ['Host a race', 'New race'],
        tracks: ['Browse', 'Track archive'],
        track: ['Track', () => state.params.title || 'Track'],
        trackEdit: ['Track creator', () => (state.editTrack && state.editTrack.id ? 'Edit track' : 'New track')],
        rankings: ['All time', 'Rankings'],
        profile: ['Your record', 'My profile'],
        profileOf: ['Racer', () => state.params.title || 'Profile'],
        settings: ['Preferences', 'Settings'],
        admin: ['Staff', 'Track admin'],
    };

    function render() {
        if (!state.open) return;
        state.token += 1;
        const body = shell();
        const draw = SCREENS[state.screen] || SCREENS.home;
        draw(body, state.token);
    }

    const current = (token) => token === state.token && state.open;

    // ----------------------------------------------------------- Pieces

    function trackCard(track, onClick) {
        const card = el('button', 'ht-card' + (track.isFeatured ? ' hot' : ''));
        card.type = 'button';
        card.append(el('div', 'name', track.name || 'Untitled'));
        const meta = el('div', 'meta');
        const cps = list(track.checkpoints).length;
        meta.append(el('span', '', track.isSprint ? 'Sprint' : 'Circuit'), el('span', '', `${cps} checkpoints`));
        if (track.raceCount) meta.append(el('span', '', `${fmtNum(track.raceCount)} races`));
        if (track.bestTime) meta.append(el('span', '', `Best ${fmtTime(track.bestTime)}`));
        card.append(meta);
        const tags = el('div', 'ht-tags');
        if (track.isFeatured) tags.append(tag('Featured', 'hot'));
        if (track.isOfficial) tags.append(tag('Official', 'teal'));
        if (track.isVerified) tags.append(tag('Verified', 'green'));
        if (!track.isPublished) tags.append(tag('Draft'));
        if (tags.children.length) card.append(tags);
        card.addEventListener('click', onClick || (() => go('track', { id: track.id, title: track.name })));
        return card;
    }

    function raceCard(race) {
        const players = list(race.players);
        const card = el('button', 'ht-card accent');
        card.type = 'button';
        card.append(el('div', 'name', race.trackName || race.raceName || 'Race'));
        const meta = el('div', 'meta');
        meta.append(el('span', '', STATUS[race.status] || 'Waiting'), el('span', '', `${race.maxLaps || 1} lap${race.maxLaps === 1 ? '' : 's'}`), el('span', '', `${players.length}/${race.maxPlayers || '?'} racers`));
        if (race.requiredBid) meta.append(el('span', '', `$${fmtNum(race.requiredBid)} buy-in`));
        card.append(meta);
        const tags = el('div', 'ht-tags');
        tags.append(tag(MODE[race.raceMode] || 'Unranked', race.raceMode === 'ranked' ? 'teal' : race.raceMode === 'pink-slip' ? 'hot' : ''));
        const classes = list(race.vehicleClass);
        if (classes.length) classes.forEach((c) => tags.append(classBadge(c)));
        else tags.append(tag('Any class'));
        card.append(tags);
        card.addEventListener('click', () => go('race', { id: race.id, title: race.trackName }));
        return card;
    }

    // ------------------------------------------------------------ Screens

    const SCREENS = {};

    SCREENS.home = async (body, token) => {
        body.append(loading());
        const home = await post('racing:loadHome');
        if (!current(token)) return;
        body.replaceChildren();

        if (!home) { body.append(empty('The racing service did not answer. Close the tablet and try again.')); return; }

        // Daily reward
        const daily = home.dailyReward;
        if (daily && typeof daily === 'object' && !Array.isArray(daily)) {
            const rewards = list(daily.rewards);
            const max = Number(daily.maxRaces) || 1;
            const races = Number(daily.races) || 0;
            const box = el('div', 'ht-daily');
            const img = el('img');
            img.src = 'tablet/img/racing/dailyReward/racing-case.png';
            img.alt = '';
            img.onerror = () => img.remove();
            const mid = el('div');
            mid.append(el('h3', '', 'Daily reward'));
            const bar = el('div', 'ht-bar');
            const fill = el('i');
            fill.style.width = `${Math.min(100, (races / max) * 100)}%`;
            bar.append(fill);
            rewards.forEach((r) => {
                const tier = el('span', 'tier' + (r.redeemed ? ' done' : races >= r.racesRequired ? ' reached' : ''));
                tier.style.left = `${Math.min(100, (r.racesRequired / max) * 100)}%`;
                tier.title = `${r.racesRequired} races`;
                bar.append(tier);
            });
            mid.append(bar, el('div', 'sub', `${races} of ${max} races today`));
            const redeemable = rewards.some((r) => !r.redeemed && races >= r.racesRequired);
            const claim = button('Redeem', 'primary', async () => {
                claim.disabled = true;
                const result = await post('racing:redeemDaily');
                toast(result && result.success ? 'Reward claimed.' : (result && result.error) || 'Nothing to claim yet.', !(result && result.success));
                if (current(token)) render();
            });
            claim.disabled = !redeemable;
            box.append(img, mid, claim);
            body.append(box);
            body.lastChild.style.marginBottom = '1.6em';
        }

        // Live lobbies
        const lobbies = list(home.activeRaces);
        const live = section('Happening now', 'All lobbies', () => navRoot('races'));
        if (lobbies.length) {
            const grid = el('div', 'ht-grid');
            lobbies.slice(0, 6).forEach((r) => grid.append(raceCard(r)));
            live.append(grid);
        } else {
            const row = el('div', 'ht-empty');
            row.append(document.createTextNode('No races are open right now. '));
            const host = button('Host one', 'primary small', () => go('raceCreate', {}));
            host.style.marginLeft = '0.6em';
            row.append(host);
            live.append(row);
        }
        body.append(live);

        // Track shelves
        [['Featured tracks', home.hotTracks], ['Most raced', home.popularTracks], ['Newest tracks', home.newTracks]].forEach(([title, tracks]) => {
            const items = list(tracks);
            if (!items.length) return;
            const s = section(title, 'Browse all', () => navRoot('tracks'));
            const grid = el('div', 'ht-grid');
            items.forEach((t) => grid.append(trackCard(t)));
            s.append(grid);
            body.append(s);
        });

        // Recent races
        const recent = list(home.lastRaces);
        const r = section('Your recent races');
        if (recent.length) r.append(recentTable(recent));
        else r.append(empty('Your finished races will show up here.'));
        body.append(r);
    };

    function recentTable(rows) {
        const table = el('table', 'ht-table');
        const head = el('tr');
        ['Pos', 'Track', 'Time', 'Racers', 'Payout'].forEach((h, i) => head.append(el('th', i >= 2 ? 'num' : '', h)));
        table.append(head);
        rows.forEach((row) => {
            const tr = el('tr', 'click');
            const pos = el('td'); pos.append(posBadge(row.position));
            tr.append(pos, el('td', '', row.raceName || row.name || 'Race'), el('td', 'num', fmtTime(row.time)), el('td', 'num', String(row.racers || '-')), el('td', 'num', row.payout ? `$${fmtNum(row.payout)}` : '-'));
            if (row.raceId) tr.addEventListener('click', () => go('race', { id: row.raceId, title: row.raceName }));
            table.append(tr);
        });
        return table;
    }

    SCREENS.races = async (body, token) => {
        const top = el('div', 'ht-row');
        top.style.marginBottom = '1.2em';
        top.append(button('Host a race', 'primary', () => go('raceCreate', {}), 'i-flag'));
        if (state.currentRace) top.append(button('My lobby', '', () => go('race', { id: state.currentRace.id, title: state.currentRace.trackName }), 'i-play'));
        body.append(top, loading());
        const races = list(await post('racing:loadActiveRaces'));
        if (!current(token)) return;
        body.lastChild.remove();
        if (!races.length) { body.append(empty('No lobbies are open. Host one and others can join from here.')); return; }
        const grid = el('div', 'ht-grid');
        races.forEach((r) => grid.append(raceCard(r)));
        body.append(grid);
    };

    SCREENS.race = async (body, token) => {
        const id = state.params.id;
        body.append(loading());
        let race = await post('racing:loadRace', { id, raceId: id });
        if (!current(token)) return;
        if ((!race || !race.id) && state.currentRace && state.currentRace.id === id) race = state.currentRace;
        body.replaceChildren();
        if (!race || !race.id) { body.append(empty('This race is no longer open.')); return; }
        state.params.title = race.trackName || race.raceName;
        const h1 = root.querySelector('.ht-title h1');
        if (h1) h1.textContent = state.params.title || 'Race';

        const players = list(race.players);
        const mine = state.me.stateId;
        const amIn = players.some((p) => String(p.stateId) === String(mine));
        const amHost = String(race.ownerStateId) === String(mine);
        const finished = race.status === 2;

        const head = el('div', 'ht-race-head');
        const info = el('div');
        const tags = el('div', 'ht-tags');
        tags.append(tag(STATUS[race.status] || 'Waiting', race.status === 1 ? 'hot' : race.status === 2 ? 'green' : 'teal'), tag(MODE[race.raceMode] || 'Unranked'));
        const classes = list(race.vehicleClass);
        if (classes.length) classes.forEach((c) => tags.append(classBadge(c))); else tags.append(tag('Any class'));
        info.append(tags);
        head.append(info);

        const actions = el('div', 'ht-row');
        if (!finished) {
            if (!amIn && race.status === 0) {
                actions.append(button('Join race', 'primary', async (e) => {
                    e.currentTarget.disabled = true;
                    const result = await post('racing:joinRace', { raceId: race.id, id: race.id });
                    toast(result && result.success ? 'You joined the lobby.' : (result && result.error) || 'Could not join.', !(result && result.success));
                    if (current(token)) render();
                }, 'i-play'));
            }
            if (amHost && race.status === 0) {
                actions.append(button('Start race', 'primary', async (e) => {
                    e.currentTarget.disabled = true;
                    const result = await post('racing:startRace', { raceId: race.id, id: race.id });
                    if (result && result.success) closeTablet();
                    else { toast((result && result.error) || 'Could not start.', true); if (current(token)) render(); }
                }, 'i-flag'));
            }
            actions.append(button('Set GPS', '', () => post('racing:startWaypoint', { trackId: race.trackId, id: race.trackId }), 'i-pin'));
            if (amIn) {
                actions.append(button('Leave', 'danger', () => confirmBox('Leave this race?', 'You will lose your place in the lobby.', 'Leave', async () => {
                    await post('racing:leaveRace');
                    state.currentRace = null;
                })));
            }
            if (amHost || state.admin) {
                actions.append(button('Disband', 'danger', () => confirmBox('Disband the lobby?', 'Everyone in it is sent home and buy-ins are refunded.', 'Disband', async () => {
                    const result = await post('racing:deleteRace', { raceId: race.id, id: race.id });
                    toast(result && result.success ? 'Lobby disbanded.' : (result && result.error) || 'Could not disband.', !(result && result.success));
                    if (current(token)) navRoot('races');
                })));
            }
        }
        head.append(actions);
        body.append(head);

        const stats = el('div', 'ht-stats');
        const stat = (label, value) => { const s = el('div', 'ht-stat'); s.append(el('small', '', label), el('b', '', value)); stats.append(s); };
        stat('Laps', String(race.maxLaps || 1));
        stat('Racers', `${players.length}/${race.maxPlayers || '?'}`);
        stat('Buy-in', race.requiredBid ? `$${fmtNum(race.requiredBid)}` : 'Free');
        stat('Ghosting', state.ghostModes[(Number(race.ghostEnabled) || 1) - 1] || 'Off');
        body.append(stats);

        const s = section(finished ? 'Results' : 'On the grid');
        if (finished) {
            const sorted = players.slice().sort((a, b) => (a.position || 99) - (b.position || 99));
            const table = el('table', 'ht-table');
            const hr = el('tr');
            ['Pos', 'Racer', 'Vehicle', 'Time', 'Best lap', 'Reward'].forEach((h, i) => hr.append(el('th', i >= 3 ? 'num' : '', h)));
            table.append(hr);
            sorted.forEach((p) => {
                const tr = el('tr', String(p.stateId) === String(mine) ? 'me' : '');
                const pos = el('td'); pos.append(posBadge(p.position));
                tr.append(pos, el('td', '', p.nickname || 'Racer'), el('td', '', (p.vehicle && p.vehicle.label) || '-'), el('td', 'num', fmtTime(p.time)), el('td', 'num', fmtTime(p.bestLapTime)), el('td', 'num', p.reward ? `$${fmtNum(p.reward)}` : '-'));
                table.append(tr);
            });
            s.append(table);
        } else if (players.length) {
            const grid = el('div', 'ht-players');
            players.forEach((p) => {
                const card = el('div', 'ht-player' + (String(p.stateId) === String(mine) ? ' me' : ''));
                if (p.vehicle && p.vehicle.class) card.append(classBadge(p.vehicle.class));
                const who = el('div', 'who');
                who.append(el('b', '', (p.nickname || 'Racer') + (String(p.stateId) === String(race.ownerStateId) ? '  (host)' : '')), el('small', '', (p.vehicle && p.vehicle.label) || 'On foot'));
                card.append(who);
                if (amHost && String(p.stateId) !== String(mine) && race.status === 0) {
                    card.append(button('Kick', 'danger small', async () => {
                        const result = await post('racing:kick', { raceId: race.id, id: race.id, stateId: p.stateId });
                        toast(result && result.success ? 'Racer removed.' : (result && result.error) || 'Could not kick.', !(result && result.success));
                        if (current(token)) render();
                    }));
                }
                grid.append(card);
            });
            s.append(grid);
        } else {
            s.append(empty('Nobody has joined yet.'));
        }
        body.append(s);
    };

    SCREENS.raceCreate = async (body, token) => {
        const draft = state.params.draft || (state.params.draft = {
            trackId: state.params.trackId || null,
            trackName: state.params.trackName || '',
            laps: 3,
            classes: [],
            buyin: 0,
            ghost: state.ghostDefault,
        });

        const form = el('div', 'ht-form');

        // Track picker
        const pick = el('div', 'wide');
        const chosen = el('div', 'ht-card accent');
        const showChosen = () => {
            chosen.replaceChildren(el('div', 'name', draft.trackName || 'Pick a track below'));
            const meta = el('div', 'meta');
            meta.append(el('span', '', draft.trackId ? 'Selected track' : 'No track selected yet'));
            chosen.append(meta);
        };
        showChosen();
        const search = el('div', 'ht-search');
        search.append(icon('i-search'));
        const q = input('', 'Search tracks by name');
        search.append(q);
        const results = el('div', 'ht-grid');
        results.style.marginTop = '0.6em';
        results.style.maxHeight = '15em';
        results.style.overflowY = 'auto';
        let timer;
        const load = async () => {
            const rows = list(await post('racing:loadTracks', { query: q.value.trim(), offset: 0, filter: '__all__', sorting: 'name:asc' }));
            if (!current(token)) return;
            results.replaceChildren();
            if (!rows.length) { results.append(empty('No tracks match.')); return; }
            rows.forEach((t) => results.append(trackCard(t, () => { draft.trackId = t.id; draft.trackName = t.name; showChosen(); })));
        };
        q.addEventListener('input', () => { clearTimeout(timer); timer = setTimeout(load, 250); });
        pick.append(field('Track', chosen), search, results);
        form.append(pick);
        load();

        // Laps
        const laps = input(draft.laps, '', 'number');
        laps.min = 1; laps.max = state.options.maxLaps;
        laps.addEventListener('input', () => { draft.laps = Math.max(1, Math.min(state.options.maxLaps, Math.floor(Number(laps.value) || 1))); });
        form.append(field('Laps (1 for a sprint)', laps));

        // Ghosting
        const ghost = select(state.ghostModes.map((label, i) => [i + 1, label]), draft.ghost);
        ghost.addEventListener('change', () => { draft.ghost = Number(ghost.value); });
        form.append(field('Ghosting at the start', ghost));

        // Classes
        const chips = el('div', 'ht-chips');
        const any = el('button', 'ht-chip' + (draft.classes.length ? '' : ' on'), 'Any class');
        any.type = 'button';
        any.addEventListener('click', () => { draft.classes = []; render(); });
        chips.append(any);
        state.classes.forEach((c) => {
            const chip = el('button', 'ht-chip' + (draft.classes.includes(c) ? ' on' : ''), `Class ${c}`);
            chip.type = 'button';
            chip.addEventListener('click', () => {
                draft.classes = draft.classes.includes(c) ? draft.classes.filter((x) => x !== c) : draft.classes.concat(c);
                chip.classList.toggle('on', draft.classes.includes(c));
                any.classList.toggle('on', draft.classes.length === 0);
            });
            chips.append(chip);
        });
        const classField = field('Allowed classes', chips);
        classField.classList.add('wide');
        form.append(classField);

        // Buy-in
        if (state.options.buyin) {
            const buyin = input(draft.buyin, '0', 'number');
            buyin.min = 0; buyin.max = state.options.buyinMax;
            buyin.addEventListener('input', () => { draft.buyin = Math.max(0, Math.min(state.options.buyinMax, Math.floor(Number(buyin.value) || 0))); });
            form.append(field(`Buy-in (up to $${fmtNum(state.options.buyinMax)})`, buyin));
        }

        body.append(form);

        const error = el('div', 'ht-error');
        const actions = el('div', 'ht-row');
        actions.style.marginTop = '1.4em';
        const create = async (ranked) => {
            if (!draft.trackId) { error.textContent = 'Pick a track first.'; return; }
            error.textContent = '';
            actions.querySelectorAll('button').forEach((b) => { b.disabled = true; });
            const result = await post('racing:createRace', {
                trackId: draft.trackId,
                maxLaps: draft.laps,
                vehicleClass: draft.classes,
                requiredBid: draft.buyin,
                ghostEnabled: draft.ghost,
                isRanked: ranked,
            });
            if (!current(token)) return;
            if (result && result.success) {
                toast('Lobby created.');
                go('race', { id: result.id, title: draft.trackName }, true);
            } else {
                error.textContent = (result && result.error) || 'The race could not be created.';
                actions.querySelectorAll('button').forEach((b) => { b.disabled = false; });
            }
        };
        actions.append(button('Create race', 'primary', () => create(false), 'i-flag'));
        if (state.canRank) actions.append(button('Create ranked race', '', () => create(true), 'i-trophy'));
        body.append(actions, error);
    };

    // Tracks list: search, filter, sort, paged.
    SCREENS.tracks = async (body, token, adminMode) => {
        const p = state.params;
        p.query = p.query || '';
        p.filter = p.filter || '__all__';
        p.sorting = p.sorting || 'default';

        const bar = el('div', 'ht-row');
        bar.style.marginBottom = '0.8em';
        const search = el('div', 'ht-search');
        search.append(icon('i-search'));
        const q = input(p.query, 'Search tracks');
        search.append(q);
        const sort = select([['default', 'Featured first'], ['name:asc', 'Name A-Z'], ['createdAt:desc', 'Newest'], ['raceCount:desc', 'Most raced'], ['checkpoints:desc', 'Longest']], p.sorting);
        sort.style.width = '13em';
        bar.append(search, sort);
        if (!adminMode) bar.append(button('Create track', 'primary', () => {
            state.editTrack = { id: 0, name: '', isSprint: false, isPublished: true, checkpoints: [], props: [] };
            go('trackEdit', {});
        }, 'i-route'));
        body.append(bar);

        const chips = el('div', 'ht-chips');
        chips.style.marginBottom = '1em';
        [['__all__', 'All'], ['isSprint', 'Sprint'], ['isLap', 'Circuit'], ['isFeatured', 'Featured'], ['isOfficial', 'Official'], ['isVerified', 'Verified']].forEach(([id, label]) => {
            const c = el('button', 'ht-chip' + (p.filter === id ? ' on' : ''), label);
            c.type = 'button';
            c.addEventListener('click', () => { p.filter = id; render(); });
            chips.append(c);
        });
        body.append(chips);

        const grid = el('div', adminMode ? '' : 'ht-grid');
        body.append(grid);
        const more = button('Load more', '', null);
        more.style.marginTop = '1em';

        let offset = 0;
        let loadingPage = false;
        const page = async (reset) => {
            if (loadingPage) return;
            loadingPage = true;
            if (reset) { offset = 0; grid.replaceChildren(loading()); }
            const rows = list(await post('racing:loadTracks', { query: p.query, offset, filter: p.filter, sorting: p.sorting === 'default' ? '' : p.sorting }));
            loadingPage = false;
            if (!current(token)) return;
            if (reset) grid.replaceChildren();
            if (reset && !rows.length) { grid.append(empty(p.query ? 'No tracks match that search.' : 'No tracks yet. Create the first one.')); more.remove(); return; }
            rows.forEach((t) => grid.append(adminMode ? adminRow(t, token) : trackCard(t)));
            offset += rows.length;
            if (rows.length >= 20) body.append(more); else more.remove();
        };
        more.addEventListener('click', () => page(false));
        let timer;
        q.addEventListener('input', () => { clearTimeout(timer); timer = setTimeout(() => { p.query = q.value.trim(); page(true); }, 250); });
        sort.addEventListener('change', () => { p.sorting = sort.value; page(true); });
        page(true);
    };

    SCREENS.track = async (body, token) => {
        const id = state.params.id;
        body.append(loading());
        const track = await post('racing:loadCurrentTrack', { trackId: id, id });
        if (!current(token)) return;
        body.replaceChildren();
        if (!track || !track.id) { body.append(empty('This track could not be found.')); return; }
        state.params.title = track.name;
        const h1 = root.querySelector('.ht-title h1');
        if (h1) h1.textContent = track.name;

        const data = track.loadedData && (track.loadedData['0'] || list(track.loadedData)[0]);
        const stats = data && (data.ranked || data.casual || data);
        const cps = list(track.checkpoints).length;
        const mineTrack = String(track.creatorStateId) === String(state.me.stateId);

        const tags = el('div', 'ht-tags');
        tags.style.marginBottom = '1em';
        tags.append(tag(track.isSprint ? 'Sprint' : 'Circuit', 'teal'));
        if (track.isFeatured) tags.append(tag('Featured', 'hot'));
        if (track.isOfficial) tags.append(tag('Official'));
        if (track.isVerified) tags.append(tag('Verified', 'green'));
        if (!track.isPublished) tags.append(tag('Draft'));
        body.append(tags);

        const actions = el('div', 'ht-row');
        actions.style.marginBottom = '1.4em';
        actions.append(button('Host a race here', 'primary', () => go('raceCreate', { trackId: track.id, trackName: track.name }), 'i-flag'));
        actions.append(button('Set GPS to start', '', async () => {
            const result = await post('racing:startWaypoint', { trackId: track.id, id: track.id });
            toast(result && result.ok ? 'Route set to the start line.' : 'No start line on this track.', !(result && result.ok));
        }, 'i-pin'));
        if (mineTrack || state.admin) {
            actions.append(button('Edit', '', async () => {
                await post('racing:editor', { id: track.id, name: track.name, isSprint: track.isSprint, isPublished: track.isPublished, checkpoints: [] });
            }, 'i-route'));
            actions.append(button('Delete', 'danger', () => confirmBox('Delete this track?', `"${track.name}" and its records will be removed. This cannot be undone.`, 'Delete', async () => {
                const result = await post('racing:deleteTrack', { trackId: track.id, id: track.id });
                toast(result && result.success ? 'Track deleted.' : (result && result.error) || 'Could not delete.', !(result && result.success));
                if (result && result.success && current(token)) navRoot('tracks');
            })));
        }
        body.append(actions);

        const s = el('div', 'ht-stats');
        const stat = (label, value) => { const b = el('div', 'ht-stat'); b.append(el('small', '', label), el('b', '', value)); s.append(b); };
        stat('Checkpoints', String(cps));
        stat('Track record', fmtTime(stats && stats.bestTime));
        stat('Your best', fmtTime(stats && stats.personalBest));
        stat('Average', fmtTime(stats && stats.avgTime));
        stat('Times set', fmtNum(stats && stats.totalRaces));
        body.append(s);

        const board = list(stats && stats.leaderboard);
        const lb = section('Leaderboard');
        if (board.length) {
            const table = el('table', 'ht-table');
            const hr = el('tr');
            ['Pos', 'Racer', 'Vehicle', 'Time', 'Best lap'].forEach((h, i) => hr.append(el('th', i >= 3 ? 'num' : '', h)));
            table.append(hr);
            board.forEach((row, i) => {
                const tr = el('tr', 'click' + (String(row.stateId) === String(state.me.stateId) ? ' me' : ''));
                const pos = el('td'); pos.append(posBadge(row.position || i + 1));
                tr.append(pos, el('td', '', row.nickname || row.name || 'Racer'), el('td', '', row.vehicle || '-'), el('td', 'num', fmtTime(row.time)), el('td', 'num', fmtTime(row.bestLap)));
                tr.addEventListener('click', () => go('profileOf', { stateId: row.stateId, title: row.nickname }));
                table.append(tr);
            });
            lb.append(table);
        } else {
            lb.append(empty('No times on this track yet. Be the first.'));
        }
        body.append(lb);
    };

    // The creator's form. Checkpoints are placed in the world (racing:editor);
    // name, shape and visibility are set here, and Save writes the lot.
    SCREENS.trackEdit = (body, token) => {
        const draft = state.editTrack || (state.editTrack = { id: 0, name: '', isSprint: false, isPublished: true, checkpoints: [], props: [] });
        const cps = list(draft.checkpoints);
        const form = el('div', 'ht-form');
        const name = input(draft.name, 'Track name');
        name.maxLength = 48;
        name.addEventListener('input', () => { draft.name = name.value; });
        const nameField = field('Name', name);
        nameField.classList.add('wide');
        form.append(nameField);

        const shape = el('div', 'ht-chips');
        [['circuit', 'Circuit (laps)', false], ['sprint', 'Sprint (A to B)', true]].forEach(([id, label, sprint]) => {
            const c = el('button', 'ht-chip' + (!!draft.isSprint === sprint ? ' on' : ''), label);
            c.type = 'button';
            c.addEventListener('click', () => { draft.isSprint = sprint; render(); });
            shape.append(c);
        });
        form.append(field('Shape', shape));
        form.append(field('Visibility', toggle('Published for everyone', draft.isPublished !== false, (v) => { draft.isPublished = v; })));
        body.append(form);

        const s = el('div', 'ht-stats');
        s.style.marginTop = '1.4em';
        const b = el('div', 'ht-stat');
        b.append(el('small', '', 'Checkpoints placed'), el('b', '', String(cps.length)));
        s.append(b);
        body.append(s);

        const error = el('div', 'ht-error');
        const actions = el('div', 'ht-row');
        actions.append(button(cps.length ? 'Edit checkpoints in the world' : 'Place checkpoints in the world', 'primary', async () => {
            await post('racing:editor', { id: draft.id, name: draft.name, isSprint: draft.isSprint, isPublished: draft.isPublished, checkpoints: cps, props: list(draft.props) });
        }, 'i-pin'));
        actions.append(button('Save track', '', async (e) => {
            if (!draft.name || draft.name.trim().length < 3) { error.textContent = 'Give the track a name (3 letters or more).'; return; }
            if (cps.length < 2) { error.textContent = 'Place at least two checkpoints first.'; return; }
            e.currentTarget.disabled = true;
            const result = await post('racing:saveTrack', { id: draft.id, name: draft.name.trim(), isSprint: !!draft.isSprint, isPublished: draft.isPublished !== false, checkpoints: cps, props: list(draft.props) });
            if (!current(token)) return;
            if (result && result.success) { state.editTrack = null; toast('Track saved.'); navRoot('tracks'); }
            else { error.textContent = (result && result.error) || 'The track could not be saved.'; e.currentTarget.disabled = false; }
        }, 'i-flag'));
        body.append(actions, error);
        const hint = el('p', '', 'Place checkpoints out in the world, then come back here to name the track and save it.');
        hint.style.color = 'var(--ht-faint)';
        hint.style.marginTop = '1em';
        body.append(hint);
    };

    SCREENS.rankings = async (body, token) => {
        const bar = el('div', 'ht-row');
        bar.style.marginBottom = '1em';
        const search = el('div', 'ht-search');
        search.append(icon('i-search'));
        const q = input('', 'Find a racer by name');
        search.append(q);
        bar.append(search);
        body.append(bar);
        const holder = el('div');
        body.append(holder);

        const show = (rows, searching) => {
            holder.replaceChildren();
            if (!rows.length) { holder.append(empty(searching ? 'No racers found.' : 'Nobody has finished a race yet.')); return; }
            const table = el('table', 'ht-table');
            const hr = el('tr');
            ['Pos', 'Racer', 'Wins', 'Races', 'Win rate'].forEach((h, i) => hr.append(el('th', i >= 2 ? 'num' : '', h)));
            table.append(hr);
            rows.forEach((row, i) => {
                const tr = el('tr', 'click' + (String(row.stateId) === String(state.me.stateId) ? ' me' : ''));
                const pos = el('td'); pos.append(posBadge(row.position || i + 1));
                const won = Number(row.wonRaces) || 0;
                const total = Number(row.totalRaces) || 0;
                tr.append(pos, el('td', '', row.nickname || 'Racer'), el('td', 'num', fmtNum(won)), el('td', 'num', fmtNum(total)), el('td', 'num', total ? `${Math.round((won / total) * 100)}%` : '-'));
                tr.addEventListener('click', () => go('profileOf', { stateId: row.stateId, title: row.nickname }));
                table.append(tr);
            });
            holder.append(table);
        };

        holder.append(loading());
        const all = list(await post('racing:loadLeaderboardUsers'));
        if (!current(token)) return;
        show(all, false);

        let timer;
        q.addEventListener('input', () => {
            clearTimeout(timer);
            timer = setTimeout(async () => {
                const text = q.value.trim();
                if (!text) return show(all, false);
                const rows = list(await post('racing:searchProfiles', { query: text }));
                if (current(token)) show(rows, true);
            }, 250);
        });
    };

    async function profileScreen(body, token, stateId) {
        body.append(loading());
        const profile = await post('racing:loadProfile', { stateId });
        if (!current(token)) return;
        body.replaceChildren();
        if (!profile || !profile.stateId) { body.append(empty('No racing record yet. Finish a race to start one.')); return; }
        const h1 = root.querySelector('.ht-title h1');
        if (h1 && state.screen === 'profileOf') h1.textContent = profile.nickname || 'Racer';

        const data = (profile.loadedData && (profile.loadedData['0'] || list(profile.loadedData)[0])) || {};
        const s = el('div', 'ht-stats');
        const stat = (label, value) => { const b = el('div', 'ht-stat'); b.append(el('small', '', label), el('b', '', value)); s.append(b); };
        stat('Races', fmtNum(data.totalRaces));
        stat('Average place', data.avgPlace ? Number(data.avgPlace).toFixed(1) : '-');
        stat('Time racing', fmtDuration(data.totalTime));
        stat('Money won', `$${fmtNum(data.deltaCash)}`);
        stat('Tracks made', fmtNum(data.tracksCreated));
        stat('Favourite class', data.mostRacedClass || '-');
        body.append(s);

        const recent = list(data.lastRaces);
        const r = section('Recent races');
        r.append(recent.length ? recentTable(recent) : empty('No races yet.'));
        body.append(r);

        const two = el('div', 'ht-grid');
        [['Most driven', list(data.mostUsedVehicles)], ['Most raced tracks', list(data.mostPlayedTracks)]].forEach(([title, rows]) => {
            const box = section(title);
            if (!rows.length) box.append(empty('Nothing yet.'));
            rows.forEach((row) => {
                const card = el('div', 'ht-card');
                card.append(el('div', 'name', row.label || row.name || '-'));
                const meta = el('div', 'meta');
                meta.append(el('span', '', `${fmtNum(row.totalRaces)} races`), el('span', '', `${fmtNum(row.wonRaces)} wins`));
                if (row.avgPlace) meta.append(el('span', '', `avg ${Number(row.avgPlace).toFixed(1)}`));
                card.append(meta);
                card.style.marginBottom = '0.4em';
                box.append(card);
            });
            two.append(box);
        });
        body.append(two);
    }

    SCREENS.profile = (body, token) => profileScreen(body, token, state.me.stateId);
    SCREENS.profileOf = (body, token) => profileScreen(body, token, state.params.stateId);

    SCREENS.settings = (body, token) => {
        const form = el('div', 'ht-form');
        const nick = input(state.settings.nickname || '', 'Shown on leaderboards and in lobbies');
        nick.maxLength = 24;
        const f = field('Racing alias', nick);
        f.classList.add('wide');
        form.append(f);
        body.append(form);
        const error = el('div', 'ht-error');
        const save = button('Save', 'primary', async () => {
            save.disabled = true;
            const settings = Object.assign({}, state.settings, { nickname: nick.value.trim() });
            const result = await post('racing:saveSettings', settings);
            if (!current(token)) return;
            save.disabled = false;
            if (result && result.success) { state.settings = settings; error.textContent = ''; toast('Settings saved.'); }
            else error.textContent = (result && result.error) || 'Could not save.';
        });
        save.style.marginTop = '1.2em';
        body.append(save, error);
    };

    function adminRow(track, token) {
        const card = el('div', 'ht-card');
        card.style.marginBottom = '0.5em';
        const top = el('div', 'ht-row');
        const name = el('div', 'name', track.name);
        name.style.flex = '1';
        top.append(name, button('Open', 'small', () => go('track', { id: track.id, title: track.name })));
        card.append(top);
        const flags = el('div', 'ht-row');
        [['isFeatured', 'Featured'], ['isOfficial', 'Official'], ['isVerified', 'Verified'], ['isPublished', 'Published']].forEach(([key, label]) => {
            flags.append(toggle(label, !!track[key], async (value) => {
                const result = await post('racing:adminUpdateTrackKey', { trackId: track.id, key, value });
                toast(result && result.track ? `${label}: ${value ? 'on' : 'off'}` : (result && result.error) || 'Could not change that.', !(result && result.track));
            }));
        });
        flags.append(button('Delete', 'danger small', () => confirmBox('Delete this track?', `"${track.name}" and its records will be removed.`, 'Delete', async () => {
            const result = await post('racing:adminDeleteTrack', { trackId: track.id });
            toast(result && result.success ? 'Track deleted.' : (result && result.error) || 'Could not delete.', !(result && result.success));
            if (result && result.success) card.remove();
        })));
        card.append(flags);
        return card;
    }

    SCREENS.admin = (body, token) => SCREENS.tracks(body, token, true);

    // -------------------------------------------------------- Open / close

    function openTablet() {
        if (state.open) return;
        state.open = true;
        root.classList.remove('hidden');
        render();
    }

    function hideTablet() {
        state.open = false;
        root.classList.add('hidden');
        root.replaceChildren();
    }

    function closeTablet() {
        hideTablet();
        post('root:close');
    }

    window.addEventListener('keydown', (event) => {
        if (!state.open || event.key !== 'Escape') return;
        const modal = root.querySelector('.ht-modal');
        if (modal) { modal.remove(); return; }
        closeTablet();
    });

    // --------------------------------------------- Events from the game
    // The same app events client/tablet.lua always sent; the names kept.

    const ACTIONS = {
        'root/setPlayerData': (p) => { if (p) state.me = { stateId: String(p.stateId ?? '0'), name: p.name || '' }; },
        'racing/setAdminMode': (p) => { state.admin = !!p; },
        'racing/setRankedAllowlist': (p) => { state.canRank = !!p; },
        'racing/setGhostModeSettings': (p) => { if (p && p.configGhostMode) state.ghostDefault = Number(p.configGhostMode) || 2; },
        'racing/setGhostModes': (p) => { const modes = list(p); if (modes.length) state.ghostModes = modes.map((m) => (typeof m === 'string' ? m : m.label)); },
        'racing/setClasses': (p) => { const classes = list(p); if (classes.length) state.classes = classes; },
        'racing/setRaceOptions': (p) => { if (p && typeof p === 'object') Object.assign(state.options, p); },
        'racing/setSettings': (p) => { state.settings = p && typeof p === 'object' && !Array.isArray(p) ? p : {}; },
        'racing/setCurrentRace': (p) => {
            state.currentRace = p && p.id ? p : null;
            if (state.open && (state.screen === 'race' || state.screen === 'races')) render();
            else if (state.open) {
                // Keep the rail's "in a lobby" marker right without redrawing the page.
                const body = root.querySelector('.ht-body');
                if (!body) render();
            }
        },
        'racing/setEditTrack': (p) => { state.editTrack = p && typeof p === 'object' ? Object.assign({ id: 0, name: '', checkpoints: [], props: [] }, p) : null; },
        'racing/setVisible': (p) => { if (p) openTablet(); else hideTablet(); },
    };

    function onEvent(payload) {
        if (!payload) return;
        if (payload.event === 'sendAppEvent') {
            const handler = ACTIONS[`${payload.app}/${payload.action}`];
            if (handler) handler(payload.payload);
            return;
        }
        if (payload.event === 'navigate' && payload.path) {
            const path = String(payload.path);
            if (path.includes('track/creator')) { state.history = []; state.screen = 'trackEdit'; state.params = {}; }
            else {
                const race = path.match(/race\/(\d+)/);
                if (race) { state.history = []; state.screen = 'race'; state.params = { id: Number(race[1]) }; }
            }
            if (state.open) render();
            return;
        }
        if (payload.event === 'raceActive') state.raceActive = !!payload.active;
    }

    window.WhipTablet = { onEvent, open: openTablet, close: hideTablet };

    // ------------------------------------------------- Browser preview
    // Opened outside the game: sample data, so every screen can be checked.

    function mock(name, data) {
        const season = { id: 0, name: 'All Time' };
        const track = (id, n, extra) => Object.assign({ id, name: n, checkpoints: Array(8 + id).fill(0), isPublished: true, isSprint: id % 3 === 0, isFeatured: id < 3, isOfficial: id % 2 === 0, isVerified: true, creatorStateId: 'HX1', raceCount: 40 - id * 3, bestTime: 61000 + id * 2300, availableSeasons: [season] }, extra || {});
        const tracks = [track(1, 'Vinewood Hills Loop'), track(2, 'Docks Sprint'), track(3, 'Great Ocean Run'), track(4, 'Downtown Circuit'), track(5, 'Senora Freeway'), track(6, 'Observatory Climb')];
        const player = (id, n, pos, cls) => ({ stateId: id, nickname: n, position: pos, time: 95000 + pos * 1300, bestLapTime: 31000 + pos * 400, reward: pos === 1 ? 7500 : 0, vehicle: { label: 'Elegy RH8', class: cls } });
        const race = (id, t, status) => ({ id, trackId: t.id, trackName: t.name, raceName: t.name, status, raceMode: id % 2 ? 'ranked' : 'unranked', ownerStateId: 'HX1', maxPlayers: 12, maxLaps: 3, requiredBid: 2500, ghostEnabled: 2, vehicleClass: ['A', 'S'], players: { HX1: player('HX1', 'Alex Rivera', 1, 'S'), HX2: player('HX2', 'Mia Tanaka', 2, 'A'), HX3: player('HX3', 'Jon Vale', 3, 'A') } });
        const recent = [1, 2, 3].map((i) => ({ raceId: 100 + i, raceName: tracks[i].name, position: i, time: 92000 + i * 2100, racers: 6, payout: i === 1 ? 5000 : 0 }));
        switch (name) {
            case 'racing:loadHome': return { lastRaces: recent, dailyReward: { races: 3, maxRaces: 8, rewards: [{ racesRequired: 2, redeemed: true }, { racesRequired: 5, redeemed: false }, { racesRequired: 8, redeemed: false }] }, hotTracks: tracks.slice(0, 2), popularTracks: {}, newTracks: tracks.slice(3, 6), activeRaces: [race(11, tracks[0], 0), race(12, tracks[3], 1)] };
            case 'racing:loadActiveRaces': return [race(11, tracks[0], 0), race(12, tracks[3], 1)];
            case 'racing:loadRace': return race(Number(data.id) || 11, tracks[0], Number(data.id) > 100 ? 2 : 0);
            case 'racing:loadTracks': return data.offset ? [] : tracks.filter((t) => !data.query || t.name.toLowerCase().includes(String(data.query).toLowerCase()));
            case 'racing:loadCurrentTrack': return Object.assign(track(Number(data.id) || 1, tracks[(Number(data.id) || 1) - 1].name), { loadedData: { 0: { ranked: { bestTime: 61234, personalBest: 63411, avgTime: 66000, totalRaces: 42, leaderboard: [player('HX2', 'Mia Tanaka', 1), player('HX1', 'Alex Rivera', 2), player('HX3', 'Jon Vale', 3)].map((p) => ({ ...p, time: p.time, bestLap: p.bestLapTime, vehicle: 'elegy2' })) } } } });
            case 'racing:loadLeaderboardUsers': return ['Alex Rivera', 'Mia Tanaka', 'Jon Vale', 'Sam Ortiz'].map((n, i) => ({ stateId: 'HX' + (i + 1), nickname: n, wonRaces: 20 - i * 4, totalRaces: 40 - i, position: i + 1 }));
            case 'racing:loadProfile': return { stateId: data.stateId || 'HX1', nickname: 'Alex Rivera', loadedData: { 0: { totalRaces: 41, avgPlace: 2.4, totalTime: 5400000, deltaCash: 48500, tracksCreated: 3, mostRacedClass: 'A', lastRaces: recent, mostUsedVehicles: [{ label: 'Elegy RH8', totalRaces: 20, wonRaces: 9, avgPlace: 1.9 }], mostPlayedTracks: [{ label: 'Docks Sprint', totalRaces: 11, wonRaces: 4 }] } } };
            case 'racing:createRace': return { success: true, id: 13 };
            case 'racing:joinRace': case 'racing:startRace': case 'racing:saveSettings': case 'racing:deleteRace': case 'racing:kick': return { success: true };
            case 'racing:startWaypoint': return { ok: true };
            case 'racing:adminUpdateTrackKey': return { track: {} };
            case 'root:close': setTimeout(openTablet, 600); return {};
            default: return {};
        }
    }

    if (!inGame) {
        document.body.style.background = 'linear-gradient(120deg, #2b3441, #5a6a7e 60%, #9aa8b8)';
        onEvent({ event: 'sendAppEvent', app: 'root', action: 'setPlayerData', payload: { stateId: 'HX1', name: 'Alex Rivera' } });
        onEvent({ event: 'sendAppEvent', app: 'racing', action: 'setAdminMode', payload: true });
        onEvent({ event: 'sendAppEvent', app: 'racing', action: 'setRankedAllowlist', payload: true });
        onEvent({ event: 'sendAppEvent', app: 'racing', action: 'setCurrentRace', payload: { id: 11, trackName: 'Vinewood Hills Loop', status: 0 } });
        onEvent({ event: 'sendAppEvent', app: 'racing', action: 'setVisible', payload: true });
    }
})();
