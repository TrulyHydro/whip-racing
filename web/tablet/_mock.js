// DEV ONLY. Not listed in fxmanifest, so the game never serves it.
// Loaded by _preview.html to run the tablet in a normal browser with sample
// data: it answers the NUI callbacks the bundle posts and sends the app events
// client/tablet.lua sends when the tablet opens.
(function () {
    var season = { id: 0, name: 'All Time', startDate: 0, endDate: Date.now() + 3e10, isFinished: false, yourPosition: null };

    function checkpoints(n) {
        var out = [];
        for (var i = 0; i < n; i++) {
            out.push({ id: i, coords: { x: -400 + Math.cos(i / n * 6.28) * 900, y: 900 + Math.sin(i / n * 6.28) * 700, z: 30, w: 0 }, modelIndex: 0, distBetweenProps: 16 });
        }
        return out;
    }

    function track(id, name) {
        return {
            id: id, name: name, checkpoints: checkpoints(14), props: [], favouriteCount: 3,
            creatorNickname: 'TrulyHydro', creatorStateId: 'HX1',
            createdAt: Date.now() - 864e5 * id, updatedAt: Date.now(),
            isPublished: true, isDeleted: false, isOfficial: id % 2 === 0, isVerified: true,
            isFeatured: id < 3, isSprint: id % 3 === 0, isFavourite: false,
            availableSeasons: [season], currentSeasonId: 0, loadedData: {},
        };
    }

    var tracks = [track(1, 'Vinewood Hills Loop'), track(2, 'Docks Sprint'), track(3, 'Great Ocean Run'),
        track(4, 'Downtown Circuit'), track(5, 'Senora Freeway'), track(6, 'Observatory Climb')];

    function player(id, name, pos) {
        return {
            stateId: id, nickname: name, crewTag: null, elo: 0, eloChange: 0, incognito: false, position: pos,
            time: 95000 + pos * 1300, bestLapTime: 46000 + pos * 400, reward: 5000 - pos * 1000, lapTimes: [],
            vehicle: { label: 'Elegy RH8', class: 'A', power: null },
        };
    }

    function race(id, t, status) {
        return {
            id: id, raceName: t.name, trackId: t.id, trackName: t.name, vehicleClass: ['A', 'S'],
            raceMode: id % 2 ? 'ranked' : 'unranked', ownerStateId: 'HX1', startTime: 0, status: status,
            players: { HX1: player('HX1', 'Alex Rivera', 1), HX2: player('HX2', 'Mia Tanaka', 2), HX3: player('HX3', 'Jon Vale', 3) },
            maxPlayers: 12, minPlayers: 1, maxLaps: 3, maxTimeAfterFirstFinish: 60, season: 0, tournament: 0,
            ghostEnabled: 1, reverseRoute: false, requiredBid: 2500, additionalReward: 0, currency: 'CASH', isPrivate: false,
        };
    }

    var lastRaces = [1, 2, 3, 4].map(function (i) {
        return {
            id: i, raceName: tracks[i].name, trackName: tracks[i].name, trackId: tracks[i].id, position: i, players: 6,
            time: 92000 + i * 2100, elo: 0, eloChange: 0, date: Date.now() - 36e5 * i, raceMode: 'unranked',
            vehicle: { label: 'Sultan RS', class: 'B' },
        };
    });

    var routes = {
        'getLocale': function () { return { lang: 'en' }; },
        'racing:loadHome': function () {
            return {
                currentElo: 0, lastRaces: lastRaces, seasonRewards: [], dailyReward: false,
                hotTracks: tracks.slice(0, 2), popularTracks: tracks.slice(2, 4), newTracks: tracks.slice(4, 6),
                activeRaces: [race(11, tracks[0], 0), race(12, tracks[3], 1)],
            };
        },
        'racing:loadTracks': function (body) { return body && body.page > 1 ? [] : tracks; },
        'racing:loadActiveRaces': function () { return [race(11, tracks[0], 0), race(12, tracks[3], 1)]; },
        'racing:loadRace': function () { return race(11, tracks[0], window.__raceStatus === undefined ? 2 : window.__raceStatus); },
        'racing:loadSeason': function () { return season; },
        'racing:loadLeaderboardUsers': function () {
            return ['Alex Rivera', 'Mia Tanaka', 'Jon Vale', 'Sam Ortiz', 'Kai Mercer', 'Dana Cole', 'Rae Lindqvist'].map(function (n, i) {
                return { source: i + 1, stateId: 'HX' + (i + 1), nickname: n, profilePicture: null, elo: 20 - i * 3, crew: null, crewTag: null, wonRaces: 20 - i * 3, totalRaces: 40 - i, position: i + 1, mostUsedVehicle: null };
            });
        },
        'racing:loadProfile': function () {
            return {
                source: 1, stateId: 'HX1', nickname: 'Alex Rivera', profilePicture: null, elo: 0, crew: null, crewTag: null,
                availableSeasons: [season], currentSeasonId: 0,
                loadedData: { '0': {
                    deltaCash: 48500, totalRaces: 41, totalTime: 5400000, tracksCreated: 3, avgPlace: 2.4, mostRacedClass: 'A',
                    lastRaces: lastRaces,
                    mostUsedVehicles: [{ label: 'Elegy RH8', name: 'Elegy RH8', wonRaces: 9, avgPlace: 1.9, totalRaces: 20, lastUsed: Date.now(), netElo: 0 }],
                    mostPlayedTracks: [{ label: 'Docks Sprint', name: 'Docks Sprint', wonRaces: 4, avgPlace: 2.1, totalRaces: 11, lastUsed: Date.now(), netElo: 0 }],
                } },
            };
        },
        'racing:loadCurrentTrack': function () { return tracks[0]; },
    };

    var real = window.fetch.bind(window);
    window.__calls = [];

    window.fetch = function (url, opts) {
        url = String(url);
        if (url.indexOf('/locales/') >= 0) return real(url.indexOf('http://127.') === 0 ? url : '../../locales/en.json');
        if (/^https?:\/\/(127\.|localhost)/.test(url) || !/^https?:/.test(url)) return real(url, opts);

        var match = url.match(/^https?:\/\/[^/]+\/(.+)$/);
        var name = match ? match[1] : url;
        var body = {};
        try { body = JSON.parse((opts && opts.body) || '{}'); } catch (e) { /* not JSON */ }

        window.__calls.push(name);
        var data = routes[name] ? routes[name](body) : {};
        return Promise.resolve(new Response(JSON.stringify(data), { headers: { 'Content-Type': 'application/json' } }));
    };

    window.GetParentResourceName = function () { return 'whip-racing'; };

    function send(app, action, payload) {
        window.postMessage({ event: 'sendAppEvent', app: app, action: action, payload: payload }, '*');
    }
    window.__send = send;
    window.__race = race;
    window.__tracks = tracks;

    window.addEventListener('load', function () {
        setTimeout(function () {
            send('racing', 'setCrewCreateMoney', 5000);
            send('racing', 'setUserCrew', false);
            send('root', 'setPlayerData', { stateId: 'HX1', name: 'Alex Rivera' });
            send('racing', 'setAvailableSeasons', [season]);
            send('racing', 'setCanCreateTracks', true);
            send('racing', 'setSettings', {});
            send('racing', 'setAdminMode', true);
            send('racing', 'setRankedAllowlist', true);
            send('racing', 'setGhostModeSettings', { allowGhostModeInUI: true, configGhostMode: 1 });
            send('racing', 'setAvailableCurrencies', [{ name: 'CASH', label: 'Cash', symbol: '$' }]);
            send('racing', 'setCurrentRace', null);
            send('racing', 'setVisible', true);
        }, 600);
    });
})();
