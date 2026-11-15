(() => {
    'use strict';

    const $ = (id) => document.getElementById(id);
    const RESOURCE = window.GetParentResourceName ? GetParentResourceName() : 'whip-racing';

    const post = (name, data = {}) =>
        fetch(`https://${RESOURCE}/${name}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json; charset=UTF-8' },
            body: JSON.stringify(data),
        }).then((r) => r.json()).catch(() => ({}));

    const state = {
        tracks: [],
        lobbies: [],
        lobby: null,
        money: 0,
        name: 'Racer',
        selectedTrack: null,
        tab: 'tracks',
        search: '',
        sort: 'size',
        setup: { laps: 1, buyin: 0, pinkSlip: false, ghostMode: 'none', raceGhost: false },
    };

    // ------------------------------------------------------------ formatting

    /** mm:ss.mmm -- full precision, for records and results. */
    const formatTime = (ms) => {
        if (ms === null || ms === undefined || ms < 0) return '--:--.---';
        const m = Math.floor(ms / 60000);
        const s = Math.floor((ms % 60000) / 1000);
        return `${m}:${String(s).padStart(2, '0')}.${String(Math.floor(ms % 1000)).padStart(3, '0')}`;
    };

    /** mm:ss.cc -- the HUD reads better with hundredths. */
    const formatClock = (ms) => {
        if (ms === null || ms === undefined || ms < 0) return '00:00.00';
        const m = Math.floor(ms / 60000);
        const s = Math.floor((ms % 60000) / 1000);
        const c = Math.floor((ms % 1000) / 10);
        return `${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}.${String(c).padStart(2, '0')}`;
    };

    const formatDelta = (ms) => {
        const sign = ms >= 0 ? '+' : '-';
        const abs = Math.abs(ms);
        return `${sign}${Math.floor(abs / 1000)}.${String(Math.floor(abs % 1000)).padStart(3, '0')}`;
    };

    /** Rajdhani's digits are proportional -- a "1" is two thirds the width of a
        "4" -- and the face carries no tabular-figure feature, so anything
        counting reshuffles itself as the digits change. Giving each digit the
        same advance is what a monospaced face used to do for free here. Only
        the digits and the sign are boxed; the separators keep their own width,
        which is what stops a clock reading like a ransom note. */
    const ticking = (text) => String(text).replace(/[0-9+-]/g, (ch) => `<i class="d">${ch}</i>`);

    const money = (n) => `${Number(n || 0).toLocaleString()}`;

    const suffix = (n) => {
        const mod100 = n % 100;
        if (mod100 >= 11 && mod100 <= 13) return 'th';
        return ['th', 'st', 'nd', 'rd'][n % 10] || 'th';
    };

    const escape = (value) =>
        String(value ?? '').replace(/[&<>"']/g, (c) =>
            ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

    const distance = (m) => (m >= 1000 ? `${(m / 1000).toFixed(2)} km` : `${Math.round(m)} m`);

    const icon = (id, cls = 'ic') => `<svg class="${cls}"><use href="#${id}"></use></svg>`;

    // ------------------------------------------------------------------ HUD

    // Rally-style corner glyphs. Every shape points right; the left-hand
    // variants are the same path mirrored by CSS.
    const PACE_SHAPES = {
        straight: '<path d="M12 21V6"/><path d="M6.8 11.2 12 6l5.2 5.2"/>',
        slight: '<path d="M9.5 21v-7.5c0-3.4 1.8-5.4 5-6.6"/><path d="M11 5 15.6 6.4 14.2 11"/>',
        turn: '<path d="M8.5 21v-8.5a3.5 3.5 0 0 1 3.5-3.5h4.5"/><path d="M13.5 5.4 17.6 9 13.5 12.6"/>',
        hairpin: '<path d="M8.5 21v-8a4.2 4.2 0 0 1 8.4 0v5"/><path d="M13.4 17.6 16.9 21 20.4 17.6"/>',
        finish: '<path d="M5 21V4M5 5h11l-1.5 3L16 11H5"/>',
    };

    /** Turns a pace code like "slight-left" into a glyph plus a mirror flag. */
    function paceGlyph(code) {
        if (!code) return null;
        const side = code.endsWith('-left') ? 'left' : code.endsWith('-right') ? 'right'
            : code === 'left' ? 'left' : code === 'right' ? 'right' : null;

        let shape = 'straight';
        if (code === 'straight') shape = 'straight';
        else if (code === 'finish') shape = 'finish';
        else if (code.startsWith('slight')) shape = 'slight';
        else if (code.startsWith('hairpin')) shape = 'hairpin';
        else shape = 'turn';

        return { svg: `<svg viewBox="0 0 24 24">${PACE_SHAPES[shape]}</svg>`, side };
    }

    function renderPace(cell, code) {
        const glyph = paceGlyph(code);
        if (!glyph) {
            cell.classList.add('hidden');
            return;
        }
        cell.classList.remove('hidden');
        cell.innerHTML = glyph.svg;
        if (glyph.side) cell.dataset.side = glyph.side;
        else cell.removeAttribute('data-side');
    }

    /** +mm.ss.mmm gap against you. Your own row and unknown gaps stay blank. */
    function gapText(row) {
        if (row.dnf) return 'DNF';
        if (row.you || row.gap === null || row.gap === undefined) return row.you ? '' : '--';

        const abs = Math.abs(row.gap);
        const m = Math.floor(abs / 60000);
        const s = Math.floor((abs % 60000) / 1000);
        const ms = Math.floor(abs % 1000);
        return `${row.gap >= 0 ? '+' : '-'}${String(m).padStart(2, '0')}.${String(s).padStart(2, '0')}.${String(ms).padStart(3, '0')}`;
    }

    function gapClass(row) {
        if (row.you || row.dnf || row.gap === null || row.gap === undefined) return '';
        return row.gap >= 0 ? 'ahead' : 'behind';
    }

    function renderHud(data) {
        if (!data) return;

        $('hudStandings').innerHTML = (data.standings || []).slice(0, 8).map((row, index) => {
            const classes = [row.you ? 'you' : '', row.dnf ? 'out' : ''].filter(Boolean).join(' ');
            return `
            <li class="${classes}">
                <span class="pos">${index + 1}</span>
                <span class="nm">${escape(row.name)}</span>
                <span class="gap ${gapClass(row)}">${ticking(gapText(row))}</span>
            </li>`;
        }).join('');

        $('hudSectors').innerHTML = (data.sectors || []).map((sector, index) => `
            <div class="sector ${sector.done ? 'done' : ''}">
                <span>Sector ${index + 1}</span>
                <b>${ticking(formatClock(sector.done ? sector.ms : 0))}</b>
            </div>`).join('');

        $('hudBest').innerHTML = ticking(formatClock(data.bestLap));
        $('hudLapTime').innerHTML = ticking(formatClock(data.lapTime));
        $('hudTime').innerHTML = ticking(formatClock(data.time));

        $('hudLap').textContent = data.lap;
        $('hudLaps').textContent = `/${data.laps}`;
        $('hudProgress').innerHTML = ticking(`${data.progress ?? 0}`) + '%';
        $('hudPlace').textContent = data.position;
        $('hudTotal').textContent = `/${data.total}`;

        const delta = $('hudDelta');
        if (data.delta === null || data.delta === undefined) {
            delta.textContent = '';
            delta.className = 'deltaline';
        } else {
            delta.innerHTML = ticking(formatDelta(data.delta));
            delta.className = `deltaline ${data.delta <= 0 ? 'up' : 'down'}`;
        }

        renderPace($('paceNow'), data.pace && data.pace.now);
        renderPace($('paceNext'), data.pace && data.pace.next);
    }

    // ------------------------------------------------------------- Countdown

    function renderCountdown(value) {
        const el = $('countdown');
        if (value === null || value === undefined) {
            el.classList.add('hidden');
            return;
        }
        el.classList.remove('hidden');
        el.classList.toggle('go', value === 0);
        $('countdownValue').textContent = value === 0 ? 'GO' : value;
        // Restart the pop animation on every tick.
        const span = $('countdownValue');
        span.style.animation = 'none';
        void span.offsetWidth;
        span.style.animation = '';
    }


    // ------------------------------------------------------------ Track map
    //
    // Los Santos as a tile pyramid, with the route drawn over it. The world to
    // pixel transform is the tile set's own, not a guess: pixel = (a*coord + b)
    // scaled by the zoom, longitude carrying world X and latitude world Y.
    const MAP = { a: 0.02072, b: 117.3, c: -0.0205, d: 172.8, tile: 256, maxZoom: 4 };

    const tileCache = new Map();

    function tileImage(zoom, tx, ty, onLoad) {
        const key = `${zoom}/${tx}/${ty}`;
        let img = tileCache.get(key);
        if (img) return img;

        img = new Image();
        img.onload = onLoad;
        // A tile outside the pyramid just never draws; the sea is black anyway.
        img.onerror = () => { img.failed = true; };
        img.src = `tablet/mapTiles/dark/${zoom}/${tx}/${ty}.jpg`;
        tileCache.set(key, img);
        return img;
    }

    const worldToPixel = (x, y, zoom) => {
        const s = Math.pow(2, zoom);
        return { x: (MAP.a * x + MAP.b) * s, y: (MAP.c * y + MAP.d) * s };
    };

    /** The tightest zoom whose route still fits the canvas, so a short track
        gets detail and a long one still fits on screen. */
    function zoomFor(span, canvasSize) {
        if (span <= 0) return MAP.maxZoom;
        const ideal = Math.log2(canvasSize / (span * MAP.a));
        return Math.max(0, Math.min(MAP.maxZoom, Math.floor(ideal)));
    }

    function drawTrackMap(points) {
        const canvas = $('trackMap');
        if (!canvas) return;

        const ctx = canvas.getContext('2d');
        const W = canvas.width;
        const H = canvas.height;

        ctx.fillStyle = '#0c0f14';
        ctx.fillRect(0, 0, W, H);
        if (!points || points.length < 2) return;

        let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity;
        points.forEach((p) => {
            minX = Math.min(minX, p.x); maxX = Math.max(maxX, p.x);
            minY = Math.min(minY, p.y); maxY = Math.max(maxY, p.y);
        });

        const zoom = zoomFor(Math.max(maxX - minX, maxY - minY, 1), Math.min(W, H));

        // Top-left of the route is min X and *max* Y, because the latitude term
        // is negative -- north is up.
        const topLeft = worldToPixel(minX, maxY, zoom);
        const bottomRight = worldToPixel(maxX, minY, zoom);

        const pad = 26;
        const routeW = Math.max(bottomRight.x - topLeft.x, 1);
        const routeH = Math.max(bottomRight.y - topLeft.y, 1);
        const scale = Math.min((W - pad * 2) / routeW, (H - pad * 2) / routeH);

        const offX = (W - routeW * scale) / 2 - topLeft.x * scale;
        const offY = (H - routeH * scale) / 2 - topLeft.y * scale;
        const toCanvas = (p) => ({ x: p.x * scale + offX, y: p.y * scale + offY });

        const size = MAP.tile * scale;
        const first = { x: Math.floor(topLeft.x / MAP.tile), y: Math.floor(topLeft.y / MAP.tile) };
        const last = { x: Math.floor(bottomRight.x / MAP.tile), y: Math.floor(bottomRight.y / MAP.tile) };
        const redraw = () => drawTrackMap(points);

        for (let tx = first.x; tx <= last.x; tx += 1) {
            for (let ty = first.y; ty <= last.y; ty += 1) {
                const img = tileImage(zoom, tx, ty, redraw);
                if (!img.complete || img.failed || !img.naturalWidth) continue;
                ctx.drawImage(img, tx * size + offX, ty * size + offY, size, size);
            }
        }

        // Route.
        ctx.strokeStyle = 'rgba(96, 165, 250, 0.95)';
        ctx.lineWidth = 3;
        ctx.lineJoin = 'round';
        ctx.lineCap = 'round';
        ctx.beginPath();
        points.forEach((p, i) => {
            const c = toCanvas(worldToPixel(p.x, p.y, zoom));
            if (i) ctx.lineTo(c.x, c.y); else ctx.moveTo(c.x, c.y);
        });
        ctx.stroke();

        // Start and finish.
        [[0, '#93c5fd'], [points.length - 1, '#bfdbfe']].forEach(([index, colour]) => {
            const c = toCanvas(worldToPixel(points[index].x, points[index].y, zoom));
            ctx.beginPath();
            ctx.arc(c.x, c.y, 6, 0, Math.PI * 2);
            ctx.fillStyle = colour;
            ctx.strokeStyle = '#0c0f14';
            ctx.lineWidth = 2.5;
            ctx.fill();
            ctx.stroke();
        });
    }

    // ---------------------------------------------------------------- Tracks

    /** Curation flags from the is* columns, shown next to the track name. */
    function badges(track) {
        const out = [];
        if (track.official) out.push('<span class="badge official">Official</span>');
        if (track.verified) out.push('<span class="badge verified">Verified</span>');
        if (track.featured) out.push('<span class="badge featured">Featured</span>');
        if (!track.published) out.push('<span class="badge draft">Draft</span>');
        return out.join('');
    }

    function visibleTracks() {
        const needle = state.search.trim().toLowerCase();
        const list = state.tracks.filter((t) => !needle || t.name.toLowerCase().includes(needle));

        // Featured tracks stay pinned to the top whichever sort is active --
        // that is the whole point of the flag.
        return list.sort((a, b) => {
            if (!!a.featured !== !!b.featured) return a.featured ? -1 : 1;
            return state.sort === 'name'
                ? a.name.localeCompare(b.name)
                : (b.checkpoints || 0) - (a.checkpoints || 0);
        });
    }

    function renderTracks() {
        const list = $('trackList');
        const tracks = visibleTracks();

        if (!tracks.length) {
            list.innerHTML = `<div class="empty">${state.tracks.length
                ? 'No track matches that search.'
                : 'No tracks yet. Build one with /raceeditor.'}</div>`;
            return;
        }

        list.innerHTML = tracks.map((track) => `
            <div class="row" data-track="${track.id}" style="--cols:3">
                ${icon(track.circuit ? 'i-loop' : 'i-flag')}
                <div class="row-name">
                    <b>${escape(track.name)}${badges(track)}</b>
                    <small>${track.sprint ? 'Sprint' : 'Circuit'}${track.mine ? ' &middot; yours' : ''}</small>
                </div>
                <div class="row-stat"><b>${track.checkpoints}</b><span>Checkpoints</span></div>
                <div class="row-stat"><b>${distance(track.distance)}</b><span>Length</span></div>
                <div class="row-stat"><b>${track.propCount || 0}</b><span>Props</span></div>
                <div class="row-acts">
                    <button class="row-act" data-act="pin" data-track="${track.id}" title="Set GPS to the start">${icon('i-pin')}</button>
                    <button class="row-act" data-act="open" data-track="${track.id}" title="Set up a race">${icon('i-play')}</button>
                </div>
            </div>`).join('');

        list.querySelectorAll('[data-track]').forEach((node) => {
            node.addEventListener('click', (event) => {
                const id = Number(node.dataset.track);
                if (node.dataset.act === 'pin') {
                    event.stopPropagation();
                    post('track:waypoint', { trackId: id });
                    return;
                }
                openTrackDetail(id);
            });
        });
    }

    async function openTrackDetail(id) {
        const track = state.tracks.find((t) => t.id === id);
        if (!track) return;

        state.selectedTrack = id;
        $('detailCrumb').textContent = `Track "${track.name}"`;
        switchTab('detail');

        $('trackDetail').innerHTML = '<div class="empty">Loading times...</div>';
        const [records, route] = await Promise.all([
            post('track:records', { trackId: id }),
            post('track:route', { trackId: id }),
        ]);
        renderTrackDetail(track, Array.isArray(records) ? records : []);
        drawTrackMap(Array.isArray(route) ? route : []);
    }

    function renderTrackDetail(track, records) {
        const ghostModes = state.ghostModes || [];

        $('trackDetail').innerHTML = `
            <div class="detail-grid">
                <div class="panel-card">
                    <p class="eyebrow">${track.sprint ? 'Sprint' : 'Circuit'}</p>
                    <h2 class="title">${escape(track.name)}${badges(track)}</h2>

                    <div class="stat-grid">
                        <div class="stat">
                            <span>Checkpoints ${icon('i-route')}</span>
                            <b>${track.checkpoints}</b>
                            <small>Gates on the route</small>
                        </div>
                        <div class="stat">
                            <span>Length ${icon('i-map')}</span>
                            <b>${distance(track.distance)}</b>
                            <small>Per lap</small>
                        </div>
                        <div class="stat">
                            <span>Record ${icon('i-trophy')}</span>
                            <b>${records[0] ? formatTime(records[0].time_ms) : '--'}</b>
                            <small>${records[0] ? escape(records[0].name) : 'Nobody has set a time'}</small>
                        </div>
                        <div class="stat">
                            <span>Props ${icon('i-car')}</span>
                            <b>${track.propCount || 0}</b>
                            <small>Placed on the route</small>
                        </div>
                    </div>

                    <div class="row-end">
                        <button class="btn ghost" id="editTrack">Edit track</button>
                        <button class="btn danger" id="deleteTrack">Delete</button>
                    </div>
                </div>

                <div class="panel-card">
                    <h3 class="section">Race setup</h3>

                    <div class="split">
                        <label class="field"><span>Laps</span>
                            <input type="number" id="setupLaps" min="1" max="${state.maxLaps || 20}" value="${state.setup.laps}"></label>
                        <label class="field"><span>Buy-in</span>
                            <input type="number" id="setupBuyin" min="0" step="100" value="${state.setup.buyin}"></label>
                    </div>

                    <div class="field"><span>Contact rules</span>
                        <div class="seg" id="setupGhost">
                            ${ghostModes.map((m) => `<button data-ghost="${m.id}" class="${state.setup.ghostMode === m.id ? 'on' : ''}">${escape(m.label)}</button>`).join('')}
                        </div>
                    </div>

                    <div class="field"><span>Extras</span>
                        <label class="check" style="margin-bottom:9px"><input type="checkbox" id="setupPink" ${state.setup.pinkSlip ? 'checked' : ''}> Pink slips</label>
                        <label class="check"><input type="checkbox" id="setupGhostRun" ${state.setup.raceGhost ? 'checked' : ''}> Race the record ghost</label>
                    </div>

                    <button class="btn" id="hostRace" style="width:100%;margin-top:6px">Open lobby</button>
                </div>
            </div>

            <div class="panel-card" style="margin-top:16px">
                <h3 class="section">Route</h3>
                <canvas id="trackMap" class="track-map" width="900" height="420"></canvas>
                </div>
            </div>

            <div class="panel-card" style="margin-top:16px">
                <h3 class="section">Fastest times</h3>
                <ol class="records">
                    ${records.length
                        ? records.map((r, i) => `
                            <li><span class="pos">${i + 1}</span>
                                <span>${escape(r.name)}<span class="muted"> &middot; ${escape(r.model || 'unknown')}</span></span>
                                <span class="t">${formatTime(r.time_ms)}</span></li>`).join('')
                        : '<li class="muted">Nobody has set a time here yet.</li>'}
                </ol>
            </div>`;

        $('setupLaps').addEventListener('change', (e) => { state.setup.laps = Number(e.target.value) || 1; });
        $('setupBuyin').addEventListener('change', (e) => { state.setup.buyin = Number(e.target.value) || 0; });
        $('setupPink').addEventListener('change', (e) => { state.setup.pinkSlip = e.target.checked; });
        $('setupGhostRun').addEventListener('change', (e) => { state.setup.raceGhost = e.target.checked; });

        $('setupGhost').querySelectorAll('[data-ghost]').forEach((node) => {
            node.addEventListener('click', () => {
                state.setup.ghostMode = node.dataset.ghost;
                $('setupGhost').querySelectorAll('button').forEach((b) => b.classList.remove('on'));
                node.classList.add('on');
            });
        });

        $('editTrack').addEventListener('click', () => post('track:edit', { trackId: track.id }));

        $('deleteTrack').addEventListener('click', async () => {
            const result = await post('track:delete', { trackId: track.id });
            if (result && result.ok) { switchTab('tracks'); refresh(); }
        });

        $('hostRace').addEventListener('click', async () => {
            const result = await post('lobby:create', { trackId: track.id, ...state.setup });
            if (result && result.ok) {
                state.lobby = result.lobby;
                switchTab('lobby');
                renderLobby();
            }
        });
    }

    // --------------------------------------------------------------- Lobbies

    function renderLobbies() {
        const list = $('lobbyList');

        if (!state.lobbies.length) {
            list.innerHTML = '<div class="empty">No open races right now. Host one from the Tracks tab.</div>';
            return;
        }

        list.innerHTML = state.lobbies.map((lobby) => `
            <div class="row" data-lobby="${lobby.id}" style="--cols:3">
                ${icon('i-flag')}
                <div class="row-name">
                    <b>${escape(lobby.trackName)}</b>
                    <small>${lobby.pinkSlip ? 'Pink slips on the line' : 'Standard rules'}</small>
                </div>
                <div class="row-stat"><b>${lobby.count}/${lobby.maxPlayers}</b><span>Racers</span></div>
                <div class="row-stat"><b>${lobby.laps}</b><span>Laps</span></div>
                <div class="row-stat"><b>${money(lobby.buyin)}</b><span>Buy-in</span></div>
                <div class="row-acts"><button class="row-act" title="Join">${icon('i-play')}</button></div>
            </div>`).join('');

        list.querySelectorAll('[data-lobby]').forEach((node) => {
            node.addEventListener('click', async () => {
                const result = await post('lobby:join', { lobbyId: Number(node.dataset.lobby) });
                if (result && result.ok) {
                    state.lobby = result.lobby;
                    switchTab('lobby');
                    renderLobby();
                }
            });
        });
    }

    // ----------------------------------------------------------------- Lobby

    const ghostLabel = (id) => {
        const found = (state.ghostModes || []).find((m) => m.id === id);
        return found ? found.label : 'Contact';
    };

    function renderLobby() {
        const wrap = $('lobbyPanel');
        const lobby = state.lobby;

        if (!lobby) {
            wrap.innerHTML = '<div class="empty">You are not in a lobby yet.</div>';
            return;
        }

        const minPlayers = Number(lobby.minPlayers ?? 2);
        const enough = lobby.players.length >= minPlayers;
        const canStart = lobby.isHost && enough;
        const startLabel = !lobby.isHost ? 'Waiting for the host' : enough ? 'Start race' : `Need ${minPlayers} racer${minPlayers === 1 ? '' : 's'}`;

        wrap.innerHTML = `
            <div class="lobby-main panel-card">
                <p class="eyebrow">${lobby.laps} lap${lobby.laps === 1 ? '' : 's'} &middot; ${distance(lobby.distance)}</p>
                <h2 class="title">${escape(lobby.trackName)}</h2>
                <p class="desc">Waiting for racers. Everyone needs to be in a car before the start.</p>
                <ul class="roster">
                    ${lobby.players.map((p) => `
                        <li class="${p.host ? 'host' : ''}">
                            <span>${escape(p.name)}</span>
                            ${p.host ? '<span class="tag">Host</span>' : ''}
                            ${p.staked ? '<span class="tag">Staked</span>' : ''}
                        </li>`).join('')}
                </ul>
            </div>
            <div class="lobby-side">
                <div class="pot"><span>Prize pot</span><b>${money(lobby.pot)}</b></div>
                <div class="panel-card">
                    <div class="field"><span>Buy-in</span><b style="font-family:var(--mono);font-size:20px">${money(lobby.buyin)}</b></div>
                    <div class="field"><span>Contact</span><b style="font-size:18px">${escape(ghostLabel(lobby.ghostMode))}</b></div>
                    ${lobby.pinkSlip ? '<div class="field"><span>Stakes</span><b style="font-size:18px;color:var(--warn)">Pink slips</b></div>' : ''}
                </div>
                <button class="btn" id="startRace" ${canStart ? '' : 'disabled'}>${startLabel}</button>
                <button class="btn ghost" id="leaveLobby">Leave lobby</button>
            </div>`;

        $('startRace').addEventListener('click', () => post('lobby:start', { lobbyId: lobby.id }));
        $('leaveLobby').addEventListener('click', async () => {
            await post('lobby:leave', { lobbyId: lobby.id });
            state.lobby = null;
            renderLobby();
            switchTab('lobbies');
            refresh();
        });
    }

    // ---------------------------------------------------------- Track editor

    const editor = {
        mode: 'nodes',
        points: [],
        props: [],
        selected: 0,
        selectedProp: 0,
        // The width the next checkpoint will be placed at. Overwritten by the
        // first push; the default only covers the frame before it lands.
        radius: 12,
        // Sprint or circuit. The tablet owns this; the editor only shows it.
        circuit: false,
        catalogue: [],
        catalogueIndex: 1,
        rotation: 0,
        placement: 'single',
        spacing: 10,
        cursor: false,
        panel: true,
        tick: { x: 0, y: 0, z: 0, heading: 0, speed: 0, street: '' },
        hasTick: false,
        trackId: null,
        hints: null,
    };

    /** 3D length of the route as it stands, including the closing leg on a circuit. */
    function routeLength(points, circuit) {
        let total = 0;
        for (let i = 0; i < points.length - 1; i += 1) {
            const a = points[i];
            const b = points[i + 1];
            total += Math.hypot(b.x - a.x, b.y - a.y, b.z - a.z);
        }
        if (circuit && points.length > 2) {
            const a = points[points.length - 1];
            const b = points[0];
            total += Math.hypot(b.x - a.x, b.y - a.y, b.z - a.z);
        }
        return total;
    }

    // A top-down blueprint of the route, drawn straight from the world
    // coordinates. It is the fastest way to see whether a track actually loops
    // back on itself without leaving the driver's seat.
    function drawMap() {
        const canvas = $('edMap');
        const ctx = canvas.getContext('2d');
        const W = canvas.width;
        const H = canvas.height;
        const pts = editor.points;
        const circuit = editor.circuit;

        ctx.clearRect(0, 0, W, H);

        ctx.strokeStyle = 'rgba(96, 165, 250, 0.10)';
        ctx.lineWidth = 1;
        for (let i = 1; i < 10; i += 1) {
            const p = (W / 10) * i;
            ctx.beginPath();
            ctx.moveTo(p, 0); ctx.lineTo(p, H);
            ctx.moveTo(0, p); ctx.lineTo(W, p);
            ctx.stroke();
        }

        // The player only joins the bounds once real telemetry has arrived,
        // otherwise the first frame stretches the map out to the world origin.
        const world = editor.hasTick ? pts.concat([editor.tick]) : pts.slice();
        if (!world.length) return;

        let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity;
        world.forEach((p) => {
            minX = Math.min(minX, p.x); maxX = Math.max(maxX, p.x);
            minY = Math.min(minY, p.y); maxY = Math.max(maxY, p.y);
        });

        const spanX = Math.max(maxX - minX, 60);
        const spanY = Math.max(maxY - minY, 60);
        const pad = 46;
        const scale = Math.min((W - pad * 2) / spanX, (H - pad * 2) / spanY);
        const cx = (minX + maxX) / 2;
        const cy = (minY + maxY) / 2;

        // North is up, so the world Y axis is flipped onto the canvas.
        const sx = (x) => W / 2 + (x - cx) * scale;
        const sy = (y) => H / 2 - (y - cy) * scale;

        if (pts.length > 1) {
            ctx.strokeStyle = 'rgba(96, 165, 250, 0.9)';
            ctx.lineWidth = 3;
            ctx.lineJoin = 'round';
            ctx.beginPath();
            pts.forEach((p, i) => (i ? ctx.lineTo(sx(p.x), sy(p.y)) : ctx.moveTo(sx(p.x), sy(p.y))));
            ctx.stroke();

            if (circuit && pts.length > 2) {
                const a = pts[pts.length - 1];
                const b = pts[0];
                ctx.setLineDash([7, 6]);
                ctx.strokeStyle = 'rgba(153, 246, 228, 0.5)';
                ctx.beginPath();
                ctx.moveTo(sx(a.x), sy(a.y));
                ctx.lineTo(sx(b.x), sy(b.y));
                ctx.stroke();
                ctx.setLineDash([]);
            }
        }

        // Props sit under the route line as small neutral marks, so you can see
        // where the scenery clusters without them competing with the gates.
        editor.props.forEach((prop, i) => {
            const on = editor.mode === 'props' && editor.selectedProp === i + 1;
            ctx.beginPath();
            ctx.arc(sx(prop.x), sy(prop.y), on ? 4 : 2.5, 0, Math.PI * 2);
            ctx.fillStyle = on ? '#bfdbfe' : 'rgba(255, 255, 255, 0.45)';
            ctx.fill();
        });

        pts.forEach((p, i) => {
            const on = editor.mode === 'nodes' && editor.selected === i + 1;
            const size = on ? 7 : 4.5;
            const x = sx(p.x);
            const y = sy(p.y);

            ctx.beginPath();
            ctx.arc(x, y, size, 0, Math.PI * 2);
            ctx.fillStyle = on ? '#bfdbfe' : (i === 0 ? '#93c5fd' : '#141922');
            ctx.strokeStyle = on ? '#bfdbfe' : (i === 0 ? '#93c5fd' : '#3b82f6');
            ctx.lineWidth = 2;
            if (on) { ctx.shadowColor = 'rgba(153, 246, 228, 0.9)'; ctx.shadowBlur = 12; }
            ctx.fill();
            ctx.stroke();
            ctx.shadowBlur = 0;

            if (on || i === 0 || i === pts.length - 1) {
                ctx.fillStyle = on ? '#bfdbfe' : 'rgba(255,255,255,0.6)';
                ctx.font = '700 12px Inter, sans-serif';
                ctx.textAlign = 'center';
                ctx.fillText(String(i + 1), x, y - size - 6);
            }
        });

        if (!editor.hasTick) return;

        // Player arrow. GTA headings run counter-clockwise from north.
        const h = (editor.tick.heading || 0) * (Math.PI / 180);
        ctx.save();
        ctx.translate(sx(editor.tick.x), sy(editor.tick.y));
        ctx.rotate(-h);
        ctx.fillStyle = '#ffffff';
        ctx.shadowColor = 'rgba(255,255,255,0.8)';
        ctx.shadowBlur = 10;
        ctx.beginPath();
        ctx.moveTo(0, -11);
        ctx.lineTo(7, 8);
        ctx.lineTo(0, 4);
        ctx.lineTo(-7, 8);
        ctx.closePath();
        ctx.fill();
        ctx.restore();
    }

    function renderHints() {
        const hints = editor.hints && editor.hints[editor.mode];
        if (!hints) return;
        $('edHints').innerHTML = hints
            .map((h) => `<div class="hint"><b>${escape(h.key)}</b>${escape(h.label)}</div>`).join('');
    }

    function renderCatalogue() {
        $('edCatalogue').innerHTML = editor.catalogue.map((entry, index) => `
            <button data-model="${index + 1}" class="${editor.catalogueIndex === index + 1 ? 'on' : ''}"
                title="${escape(entry.model)}">${escape(entry.label)}</button>`).join('');

        $('edCatalogue').querySelectorAll('[data-model]').forEach((node) => {
            node.addEventListener('click', () => post('creator:catalogue', { index: Number(node.dataset.model) }));
        });

        $('edRotation').textContent = `${Math.round(editor.rotation)}°`;

        const pair = editor.placement === 'pair';
        $('edPlacement').querySelectorAll('[data-place]').forEach((node) =>
            node.classList.toggle('on', (node.dataset.place === 'pair') === pair));

        $('edSpacingValue').textContent = pair ? `${editor.spacing.toFixed(1)} m` : '--';
        $('edSpacing').disabled = !pair;
        // Leave the slider alone while it is being dragged, or the echo from
        // the client fights the thumb.
        if (document.activeElement !== $('edSpacing')) $('edSpacing').value = editor.spacing;
    }

    /** Prop mode reuses the node rail: same rows, different payload. */
    function renderPropList() {
        const list = $('creatorPoints');
        const props = editor.props;

        if (!props.length) {
            list.innerHTML = `
                <div class="ed-empty">
                    <b>No props yet</b>
                    Pick a model above, line the ghost up on the road and press <kbd>E</kbd>.
                </div>`;
            return;
        }

        const labelFor = (model) => {
            const found = editor.catalogue.find((e) => e.model === model);
            return found ? found.label : model;
        };

        list.innerHTML = props.map((prop, index) => {
            const number = index + 1;
            return `
                <div class="node ${editor.selectedProp === number ? 'on' : ''}" data-index="${number}">
                    <span class="n">${number}</span>
                    <span class="r">${escape(labelFor(prop.model))}</span>
                    <span class="acts">
                        <button class="mini warn" data-pact="del" data-index="${number}" title="Remove">&#10005;</button>
                    </span>
                </div>`;
        }).join('');

        list.querySelectorAll('.node').forEach((node) => {
            node.addEventListener('click', (e) => {
                if (e.target.dataset.pact) return;
                post('creator:propSelect', { index: Number(node.dataset.index) });
            });
        });

        list.querySelectorAll('[data-pact]').forEach((node) => {
            node.addEventListener('click', (e) => {
                e.stopPropagation();
                const index = Number(node.dataset.index);
                // Remove is the only row action on a prop now.
                post('creator:propDelete', { index });
            });
        });
    }

    function renderNodes() {
        const list = $('creatorPoints');
        const pts = editor.points;

        if (!pts.length) {
            list.innerHTML = `
                <div class="ed-empty">
                    <b>No nodes yet</b>
                    Drive to the start line and press <kbd>E</kbd> to drop your first checkpoint.
                </div>`;
            return;
        }

        list.innerHTML = pts.map((point, index) => {
            const number = index + 1;
            const tag = number === 1 ? 'START' : number === pts.length ? 'FINISH' : `r ${Number(point.radius).toFixed(0)}m`;
            return `
                <div class="node ${editor.selected === number ? 'on' : ''}" data-index="${number}">
                    <span class="n">${number}</span>
                    <span class="r">${tag}</span>
                    <span class="acts">
                        <button class="mini" data-act="move" data-index="${number}" title="Move to my position">SET</button>
                        <button class="mini" data-act="wide" data-index="${number}" title="Wider">+</button>
                        <button class="mini" data-act="tight" data-index="${number}" title="Tighter">&minus;</button>
                        <button class="mini warn" data-act="del" data-index="${number}" title="Remove">&#10005;</button>
                    </span>
                </div>`;
        }).join('');

        list.querySelectorAll('.node').forEach((node) => {
            node.addEventListener('click', (e) => {
                if (e.target.dataset.act) return;
                post('creator:select', { index: Number(node.dataset.index) });
            });
        });

        list.querySelectorAll('[data-act]').forEach((node) => {
            node.addEventListener('click', (e) => {
                e.stopPropagation();
                const index = Number(node.dataset.index);
                const point = editor.points[index - 1];

                switch (node.dataset.act) {
                    case 'move': post('creator:moveHere', { index }); break;
                    case 'del': post('creator:delete', { index }); break;
                    case 'wide': post('creator:radius', { index, radius: point.radius + 2 }); break;
                    case 'tight': post('creator:radius', { index, radius: point.radius - 2 }); break;
                }
            });
        });
    }

    function renderEditorStats() {
        const circuit = editor.circuit;
        const isProps = editor.mode === 'props';
        const selected = isProps
            ? editor.props[editor.selectedProp - 1]
            : editor.points[editor.selected - 1];

        $('edNodes').textContent = editor.points.length;
        $('edPropCount').textContent = editor.props.length;
        $('edLength').textContent = distance(routeLength(editor.points, circuit));
        $('edShape').textContent = circuit ? 'Circuit' : 'Sprint';

        if (!selected) {
            // With no node selected the width keys aim at the checkpoint about
            // to be dropped, so say that rather than "nothing selected" -- the
            // keys are doing something, just not to a placed node.
            $('edSelInfo').textContent = isProps
                ? 'No prop selected'
                : `Next checkpoint - ${Number(editor.radius).toFixed(0)} m gate`;
        } else if (isProps) {
            $('edSelInfo').textContent = `Prop ${editor.selectedProp} - ${Math.round(selected.heading)}°`;
        } else {
            $('edSelInfo').textContent = `Node ${editor.selected} - ${Number(selected.radius).toFixed(0)} m gate`;
        }

    }

    function renderCreator(data) {
        if (data.mode) editor.mode = data.mode;
        editor.points = data.points || [];
        editor.props = data.props || [];
        editor.selected = data.selected || 0;
        editor.selectedProp = data.selectedProp || 0;
        if (typeof data.radius === 'number') editor.radius = data.radius;
        if (typeof data.circuit === 'boolean') editor.circuit = data.circuit;
        editor.cursor = !!data.cursor;
        editor.panel = data.panel !== false;
        if (data.catalogueIndex) editor.catalogueIndex = data.catalogueIndex;
        if (data.placement) editor.placement = data.placement;
        if (typeof data.spacing === 'number') editor.spacing = data.spacing;
        // `catalogue` is the model list and only arrives with the open payload;
        // `catalogueIndex` is the selection and arrives on every push.
        if (Array.isArray(data.catalogue)) editor.catalogue = data.catalogue;

        const isProps = editor.mode === 'props';

        const root = $('creator');
        root.dataset.cursor = editor.cursor ? 'on' : 'off';
        root.dataset.panel = editor.panel ? 'on' : 'off';
        root.dataset.mode = editor.mode;
        $('edReveal').classList.toggle('hidden', editor.panel);

        const mode = $('edMode');
        mode.dataset.mode = editor.cursor ? 'cursor' : 'drive';
        mode.querySelector('.ed-mode-text').textContent = editor.cursor ? 'Cursor' : 'Drive';

        $('edModes').querySelectorAll('[data-mode]').forEach((node) =>
            node.classList.toggle('on', node.dataset.mode === editor.mode));

        $('edPicker').classList.toggle('hidden', !isProps);
        $('edRailTitle').textContent = isProps ? 'Placed props' : 'Route nodes';
        $('edDropLabel').textContent = isProps ? 'Place prop' : 'Drop node';


        if (isProps) { renderCatalogue(); renderPropList(); } else { renderNodes(); }
        renderHints();
        renderEditorStats();
        drawMap();
    }

    function renderTick(data) {
        editor.tick = data;
        editor.hasTick = true;
        if (typeof data.rotation === 'number' && editor.mode === 'props') {
            editor.rotation = data.rotation;
            $('edRotation').textContent = `${Math.round(data.rotation)}°`;
        }
        $('edSpeed').textContent = data.speed;
        $('edCoords').textContent = `${data.x.toFixed(1)}, ${data.y.toFixed(1)}, ${data.z.toFixed(1)}`;
        $('edStreet').textContent = data.street || '-';
        drawMap();
    }

    $('edMode').addEventListener('click', () => post('creator:cursor', { state: !editor.cursor }));
    $('edCollapse').addEventListener('click', () => post('creator:panel'));
    $('edReveal').addEventListener('click', () => post('creator:panel'));
    $('edDrop').addEventListener('click', () => post('creator:place'));
    $('edUndo').addEventListener('click', () => post('creator:undo'));
    $('edFinish').addEventListener('click', () => post('creator:finish'));
    $('edQuit').addEventListener('click', () => post('creator:quit'));

    $('edPlacement').querySelectorAll('[data-place]').forEach((node) => {
        node.addEventListener('click', () => post('creator:placement', { mode: node.dataset.place }));
    });

    $('edSpacing').addEventListener('input', (event) => {
        editor.spacing = Number(event.target.value);
        $('edSpacingValue').textContent = `${editor.spacing.toFixed(1)} m`;
        post('creator:spacing', { spacing: editor.spacing });
    });

    $('edModes').querySelectorAll('[data-mode]').forEach((node) => {
        node.addEventListener('click', () => post('creator:mode', { mode: node.dataset.mode }));
    });

    function openEditor(payload) {
        const track = payload.track || null;
        editor.trackId = track ? track.id : null;
        editor.hasTick = false;
        editor.hints = payload.hints || null;
        editor.catalogue = Array.isArray(payload.catalogue) ? payload.catalogue : [];
        editor.catalogueIndex = payload.catalogueIndex || 1;
        editor.placement = payload.placement || 'single';
        editor.spacing = payload.spacing || 10;

        const limits = payload.spacingLimits;
        if (limits) {
            $('edSpacing').min = limits.min;
            $('edSpacing').max = limits.max;
            $('edSpacing').step = limits.step;
        }
        editor.rotation = 0;

        $('edKicker').textContent = track ? `Editing #${track.id}` : 'New track';
        $('edModes').classList.toggle('hidden', payload.propsEnabled === false);
        editor.circuit = !!(track && track.circuit);

        $('creator').classList.remove('hidden');
        renderCreator(payload);
    }

    // --------------------------------------------------------------- Results

    function renderResults(data) {
        $('resultsTrack').textContent = `${data.trackName} - ${data.laps} lap${data.laps === 1 ? '' : 's'}`;

        $('resultsRows').innerHTML = data.rows.map((row) => {
            if (row.dnf) {
                return `<li class="out"><span class="place">&mdash;</span><span>${escape(row.name)}</span><span class="time">DNF</span><span></span></li>`;
            }
            return `
                <li class="${row.place === 1 ? 'win' : ''}">
                    <span class="place">${row.place}${suffix(row.place)}</span>
                    <span>${escape(row.name)}${row.record ? ' <span class="tag">Record</span>' : ''}</span>
                    <span class="time">${formatTime(row.time)}${row.place > 1 ? ` <span class="muted">+${(row.gap / 1000).toFixed(3)}</span>` : ''}</span>
                    <span class="cash">${row.payout ? money(row.payout) : ''}</span>
                </li>`;
        }).join('');

        const slips = $('resultsSlips');
        if (data.pinkSlips && data.pinkSlips.length) {
            slips.classList.remove('hidden');
            slips.innerHTML = `Pink slips collected: ${data.pinkSlips
                .map((s) => `<b>${escape(s.model || s.plate)}</b> from ${escape(s.from)}`).join(', ')}`;
        } else {
            slips.classList.add('hidden');
        }

        $('results').classList.remove('hidden');
    }

    $('resultsClose').addEventListener('click', () => {
        $('results').classList.add('hidden');
        post('close');
    });

    // ------------------------------------------------------------------ Tabs

    // The detail view is a child of Tracks, so the nav keeps Tracks lit while
    // you are inside it.
    const NAV_FOR = { tracks: 'tracks', detail: 'tracks', lobbies: 'lobbies', lobby: 'lobby' };

    function switchTab(tab) {
        state.tab = tab;
        document.querySelectorAll('.nav-tab').forEach((node) =>
            node.classList.toggle('active', node.dataset.tab === NAV_FOR[tab]));
        document.querySelectorAll('[data-panel]').forEach((node) =>
            node.classList.toggle('hidden', node.dataset.panel !== tab));
    }

    document.querySelectorAll('.nav-tab').forEach((node) => {
        node.addEventListener('click', () => switchTab(node.dataset.tab));
    });

    $('detailBack').addEventListener('click', () => switchTab('tracks'));
    $('detailClose').addEventListener('click', () => post('close'));
    $('closeBtn').addEventListener('click', () => post('close'));

    $('trackSearch').addEventListener('input', (e) => {
        state.search = e.target.value;
        renderTracks();
    });

    $('trackSortName').addEventListener('click', () => {
        state.sort = 'name';
        $('trackSortName').classList.add('active');
        $('trackSortSize').classList.remove('active');
        renderTracks();
    });

    $('trackSortSize').addEventListener('click', () => {
        state.sort = 'size';
        $('trackSortSize').classList.add('active');
        $('trackSortName').classList.remove('active');
        renderTracks();
    });

    async function refresh() {
        const data = await post('menu:refresh');
        if (data) applyMenu(data);
    }

    function applyMenu(data) {
        // An empty Lua table serialises to {} rather than [], which would make
        // every later .filter/.map throw and take the whole menu down with it.
        const asArray = (value) => (Array.isArray(value) ? value : []);

        state.tracks = asArray(data.tracks);
        state.lobbies = asArray(data.lobbies);
        state.lobby = data.lobby || state.lobby;
        state.money = data.money || 0;
        if (data.name) state.name = data.name;
        if (data.ghostModes) state.ghostModes = data.ghostModes;
        if (data.maxLaps) state.maxLaps = data.maxLaps;

        $('profileName').textContent = state.name;
        $('walletLine').textContent = money(state.money);
        renderTracks();
        renderLobbies();
        renderLobby();
    }

    // -------------------------------------------------------------- Messages

    window.addEventListener('message', (event) => {
        const payload = event.data || {};

        // The tablet lives in this page (web/tablet.js) -- no frame, so its
        // requests reach the game on Enhanced. Its messages are keyed on
        // `event`; ours on `action`, so the two never collide.
        if (payload.event) {
            if (window.WhipTablet) window.WhipTablet.onEvent(payload);
            return;
        }

        const { action, data } = payload;

        switch (action) {
            case 'open': {
                const payload = data.payload || {};
                if (data.screen === 'creator') {
                    openEditor(payload);
                } else if (data.screen === 'results') {
                    renderResults(payload);
                } else {
                    applyMenu(payload);
                    switchTab(state.lobby ? 'lobby' : 'tracks');
                    $('app').classList.remove('hidden');
                }
                break;
            }

            case 'close':
                $('app').classList.add('hidden');
                $('creator').classList.add('hidden');
                $('results').classList.add('hidden');
                break;

            case 'hud':
                $('hud').classList.toggle('hidden', !data.visible);
                if (data.visible) renderHud(data.payload);
                break;

            case 'tablet':
                if (window.WhipTablet) {
                    if (data.open) window.WhipTablet.open(); else window.WhipTablet.close();
                }
                break;

            case 'countdown':
                renderCountdown(data.value);
                break;

            case 'lobby':
                state.lobby = data || null;
                renderLobby();
                if (!data && state.tab === 'lobby') switchTab('lobbies');
                break;

            case 'creator':
                renderCreator(data);
                break;

            case 'creator:tick':
                renderTick(data);
                break;

            case 'focus':
                break;
        }
    });

    document.addEventListener('keydown', (event) => {
        const editorOpen = !$('creator').classList.contains('hidden');

        // Alt hands control back to the car without touching the route.
        if (editorOpen && event.key === 'Alt') {
            event.preventDefault();
            post('creator:cursor', { state: false });
            return;
        }

        if (event.key !== 'Escape') return;

        if (!$('app').classList.contains('hidden')) {
            // Escape steps out of a track detail before it closes the tablet.
            if (state.tab === 'detail') switchTab('tracks');
            else post('close');
        } else if (editorOpen) {
            post('creator:cursor', { state: false });
        } else if (!$('results').classList.contains('hidden')) {
            $('results').classList.add('hidden');
            post('close');
        }
    });
})();
