// ==UserScript==
// @name         海角m3u8提取器 (全通道版)
// @namespace    haijiao-extractor
// @version      5.9
// @description  利用多种捕获通道提取海角视频完整版m3u8地址，支持在线播放、自定义解密、下载、广告拦截、自动死链清理与画质选择
// @require      https://cdn.jsdelivr.net/npm/hls.js@1.5.8
// @author       Custom
// @match        *://*.haijiao.com/*
// @match        *://haijiao.com/*
// @match        *://*.haijiao.ai/*
// @match        *://haijiao.ai/*
// @match        *://*.hjcx.cc/*
// @match        *://hjcx.cc/*
// @match        *://*.hjcx.org/*
// @match        *://hjcx.org/*
// @match        *://*.huajitv.com/*
// @match        *://*/post/details*
// @match        *://*/videoplay*
// @grant        GM_addStyle
// @grant        GM_setClipboard
// @grant        GM_xmlhttpRequest
// @grant        GM_setValue
// @grant        GM_getValue
// @grant        unsafeWindow
// @connect      haijiao.com
// @connect      haijiao.ai
// @connect      hjcx.cc
// @connect      hjcx.org
// @connect      *
// @run-at       document-start
// @license      MIT
// ==/UserScript==

(function () {
    'use strict';

    // ========== 数据存储 ==========
    let capturedUrls = []; // { url: string, sources: Set<string>, timestamp: number, playable: boolean|null }
    const deadUrls = new Set(); // 存放校验失败的失效归一化 URL，防止重复拉取和显示

    // ========== 解密相关常量 ==========

    /** 海角自定义字符表（用于替换后再做标准 Base64 解码） */
    const CUSTOM_CHARSET = 'ABCD*EFGHIJKLMNOPQRSTUVWX#YZabcdefghijklmnopqrstuvwxyz1234567890';
    const STANDARD_B64   = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

    // ========== 工具函数 ==========

    /** 自定义字符表替换：将海角混淆字符映射回标准 Base64 字符 */
    function swapCharset(s) {
        if (!s || typeof s !== 'string') return s;
        return [...s].map(c => {
            const idx = CUSTOM_CHARSET.indexOf(c);
            return idx === -1 ? c : STANDARD_B64[idx];
        }).join('');
    }

    /** 自定义字符表解码（swap + atob + URI解码）— 与 KEJIYU 脚本同源 */
    function customDecode(s) {
        try {
            const swapped = swapCharset(s);
            const raw = atob(swapped);
            return decodeURIComponent([...raw].map(c =>
                '%' + c.charCodeAt(0).toString(16).padStart(2, '0')
            ).join(''));
        } catch (e) {
            return null;
        }
    }

    /** 标准三层 Base64 解码 */
    function tripleBase64Decode(text) {
        try {
            return JSON.parse(atob(atob(atob(text))));
        } catch (e) {
            return null;
        }
    }

    /** 智能解码：先尝试标准三层 Base64，失败则尝试自定义字符表解码 */
    function smartDecode(text) {
        if (!text || typeof text !== 'string') return null;

        // 尝试1：标准三层 Base64
        const r1 = tripleBase64Decode(text);
        if (r1) return r1;

        // 尝试2：自定义字符表解码（可能嵌套 JSON）
        try {
            const decoded = customDecode(text);
            if (decoded) {
                const parsed = JSON.parse(decoded);
                return parsed;
            }
        } catch (e) { /* 非 JSON */ }

        // 尝试3：单层自定义字符表 + atob
        try {
            const swapped = swapCharset(text);
            const once = atob(swapped);
            return JSON.parse(once);
        } catch (e) { /* ignore */ }

        return null;
    }

    /** 剥离预览标记 */
    function stripPreviewTag(prefix) {
        if (!prefix) return prefix;
        return prefix.replace(/_i_preview_?$/, '').replace(/_i_$/, '');
    }

    /** 从 m3u8 内容反推完整版地址（支持绝对 URL 与相对路径 ts、自动携带/继承 token 鉴权参数） */
    function getRealVideoSrc(content, requestUrl) {
        if (!content || typeof content !== 'string') return '';

        // 提取原请求中的 query 参数（含有 token/鉴权信息）
        let queryParams = '';
        try {
            if (requestUrl) {
                const u = new URL(requestUrl);
                queryParams = u.search;
            }
        } catch (e) {
            const qIdx = requestUrl ? requestUrl.indexOf('?') : -1;
            if (qIdx !== -1) {
                queryParams = requestUrl.substring(qIdx);
            }
        }

        const lines = content.split('\n');
        for (const line of lines) {
            const trimmed = line.trim();
            if (!trimmed || trimmed.startsWith('#')) continue;

            // 匹配绝对 URL 的 ts 文件
            try {
                if (trimmed.startsWith('http')) {
                    const u = new URL(trimmed);
                    const match = u.pathname.match(/(.*\/)([\w_]+_?)\d+\.ts$/);
                    if (match) {
                        let prefix = stripPreviewTag(match[2]);
                        u.pathname = match[1] + prefix + '.m3u8';
                        return u.toString(); // 自动保留了 ts 的 query 参数
                    }
                }
            } catch (e) { /* ignore */ }

            // 相对路径或正则匹配
            const tsMatch = trimmed.match(/^((?:https?:\/\/[^\/]+)?.*\/)([\w_]+_?)\d+\.ts(\?.*)?/);
            if (tsMatch) {
                const baseUrl = tsMatch[1];
                let prefix = stripPreviewTag(tsMatch[2]);
                const lineQuery = tsMatch[3] || queryParams;
                return baseUrl + prefix + '.m3u8' + lineQuery;
            }

            // 纯文件名情况
            const simpleMatch = trimmed.match(/([\w_]+_?)\d+\.ts/);
            if (simpleMatch) {
                let baseUrl = '';
                if (requestUrl) {
                    try {
                        const u = new URL(requestUrl);
                        const lastSlash = u.pathname.lastIndexOf('/');
                        u.pathname = u.pathname.substring(0, lastSlash + 1);
                        baseUrl = u.origin + u.pathname;
                    } catch (e) {
                        const cleanUrl = requestUrl.split('?')[0];
                        baseUrl = cleanUrl.substring(0, cleanUrl.lastIndexOf('/') + 1);
                    }
                }
                let prefix = stripPreviewTag(simpleMatch[1]);
                return baseUrl + prefix + '.m3u8' + queryParams;
            }
        }
        return '';
    }

    /** 从 ts 文件 URL 反推 m3u8 地址（自动保留原 TS 链接的 token 鉴权参数，防止 403） */
    function tsUrlToM3u8(tsUrl) {
        try {
            const u = new URL(tsUrl);
            const pathname = u.pathname;
            const match = pathname.match(/(.*\/)([\w_]+_?)\d+\.ts$/);
            if (match) {
                let prefix = stripPreviewTag(match[2]);
                u.pathname = match[1] + prefix + '.m3u8';
                return u.toString(); // 自动携带所有 query 参数 (token, sign 等)
            }
        } catch (e) {
            const match = tsUrl.match(/(.*\/)([\w_]+_?)\d+\.ts(\?.*)?$/);
            if (match) {
                let prefix = stripPreviewTag(match[2]);
                const query = match[3] || '';
                return match[1] + prefix + '.m3u8' + query;
            }
        }
        return '';
    }

    // ========== DNS 预解析 + TCP 预连接 ==========
    /** 已完成预解析的域名集合，避免重复插入 link 标签 */
    const prefetchedHosts = new Set();
    /** 为给定 m3u8 URL 的域名动态创建 dns-prefetch 与 preconnect 标签 */
    function addDnsPrefetch(url) {
        try {
            const host = new URL(url).origin;
            if (prefetchedHosts.has(host)) return;
            prefetchedHosts.add(host);
            const head = document.head || document.documentElement;
            if (!head) return;
            const dns = document.createElement('link');
            dns.rel = 'dns-prefetch';
            dns.href = host;
            head.appendChild(dns);
            const pre = document.createElement('link');
            pre.rel = 'preconnect';
            pre.href = host;
            pre.crossOrigin = 'anonymous';
            head.appendChild(pre);
            console.log('[m3u8提取] DNS预解析+预连接:', host);
        } catch (e) { /* ignore */ }
    }

    /**
     * URL 标准化：去掉动态查询参数（token、时间戳、签名等），仅保留 origin + pathname。
     * 用于去重比较——同一视频的 m3u8 常常带不同的 token/时间戳参数，若按完整 URL
     * 精确比较会导致大量“同一路径、不同参数”的重复条目（尤其 Perf 通道反复捕获）。
     */
    /**
     * 通用主播放列表文件名：不同 CDN 命名习惯不同（index/playlist/master/main），
     * 但通常指向同一视频的主 m3u8。去重时将这些通用名归一化为同一 key，
     * 避免“同目录、不同通用文件名”被记录成多条重复条目。
     */
    const GENERIC_M3U8_NAMES = ['index.m3u8', 'playlist.m3u8', 'master.m3u8', 'main.m3u8'];
    function normalizeM3u8Url(url) {
        try {
            const u = new URL(url);
            // 常见动态参数：token、时间戳、签名、鉴权、过期时间、随机数等
            const dynamicParams = ['token', 't', 'ts', 'timestamp', 'sign', 'auth', 'expire', 'e', 'nonce', 'wsSecret', 'wsTime'];
            dynamicParams.forEach(p => u.searchParams.delete(p));
            let pathname = u.pathname;
            // 归一化通用主播放列表文件名（index.m3u8 / playlist.m3u8 等 → 同一目录 key）
            const lastSlash = pathname.lastIndexOf('/');
            const fileName = (lastSlash >= 0 ? pathname.slice(lastSlash + 1) : pathname).toLowerCase();
            if (GENERIC_M3U8_NAMES.includes(fileName)) {
                pathname = pathname.slice(0, lastSlash + 1) + '__playlist__.m3u8';
            }
            // 仅用 origin + pathname 作为唯一标识（忽略剩余参数差异）
            return u.origin + pathname;
        } catch (e) {
            return url;
        }
    }

    /**
     * 添加捕获结果。
     * 去重策略：以“标准化后的 URL（去动态参数）”作为唯一 key。
     * - 已存在相同标准化 key 时，只追加新的来源 badge，不新增条目；
     * - 完整原始 URL（带参数）仍保留在 item.url，仅在比较时使用标准化版本。
     * 这样可避免同一路径、不同 token/时间戳的 m3u8 被重复记录（如 Perf 通道多次捕获）。
     */
    /**
     * 可信来源：这些通道的 URL 来自真实播放 / 解密流程，基本可直接播放；
     * 其余来源（Perf / 存储 / WebSocket / TS反推）可能捕获到过期或非主播放列表
     * 地址，需验证后才能确认可播放性。
     */
    const RELIABLE_SOURCES = new Set(['XHR Hook', 'Fetch Hook', 'API解密', '播放器劫持', 'DOM监控', 'MSE监控', 'Blob捕获']);

    /** 根据 URL 定位捕获条目并设置其可播放状态（true=可播 / false=不可用，失效则直接剔除并加入黑名单） */
    function setUrlPlayable(url, playable) {
        try {
            const normKey = normalizeM3u8Url(url);
            if (playable === false) {
                // 验证失败，移入死链黑名单，并从当前捕获列表里彻底删除，保持界面绝对整洁
                deadUrls.add(normKey);
                capturedUrls = capturedUrls.filter(i => i.normKey !== normKey);
                console.log(`[m3u8提取] 自动验证失败，已移除死链: ${url}`);
                updateUI();
                return;
            }
            const item = capturedUrls.find(i => i.normKey === normKey);
            if (item && item.playable !== playable) {
                item.playable = playable;
                updateUI();
            }
        } catch (e) { /* ignore */ }
    }

    /**
     * 轻量验证捕获到的 m3u8 是否可达且为真正的播放列表（Perf 通道专用）。
     * 使用 GM_xmlhttpRequest 拉取内容，避免 CORS 限制；根据状态码/内容标记可播放性。
     */
    function verifyCapturedUrl(url) {
        if (typeof GM_xmlhttpRequest === 'undefined') return;
        try {
            GM_xmlhttpRequest({
                method: 'GET',
                url: url,
                timeout: 8000,
                headers: {
                    'Referer': location.href,
                    'Origin': location.origin
                },
                onload: function (resp) {
                    try {
                        const text = (resp && typeof resp.responseText === 'string') ? resp.responseText : '';
                        const ok = resp && resp.status >= 200 && resp.status < 300 &&
                            (text.includes('#EXTM3U') || text.includes('.ts'));
                        setUrlPlayable(url, !!ok);
                    } catch (e) { setUrlPlayable(url, false); }
                },
                onerror: function () { setUrlPlayable(url, false); },
                ontimeout: function () { setUrlPlayable(url, false); }
            });
        } catch (e) { /* ignore */ }
    }

    function addCaptured(url, source) {
        if (!url || typeof url !== 'string') return;
        url = url.trim();
        if (!url.startsWith('http')) return;
        // 屏蔽误判：API endpoint 不能作为最终 m3u8 地址
        if (/\/api\//.test(url)) return;
        // 直接丢弃预览版
        if (/_i_preview/i.test(url)) {
            console.log(`[m3u8提取][${source}] 丢弃预览版: ${url}`);
            return;
        }
        // 用标准化后的 URL 去重（忽略动态参数差异）
        const normKey = normalizeM3u8Url(url);
        // 如果该 URL 已被判定为死链，直接忽略，不录入也不重复请求
        if (deadUrls.has(normKey)) return;

        const existing = capturedUrls.find(item => item.normKey === normKey);
        if (existing) {
            // 可信来源出现 → 直接标记为可播放
            let changed = false;
            if (RELIABLE_SOURCES.has(source) && existing.playable !== true) {
                existing.playable = true;
                changed = true;
            }
            if (existing.sources.has(source)) {
                if (changed) updateUI();
                return; // 完全重复，跳过
            }
            existing.sources.add(source);
            console.log(`[m3u8提取][${source}] 追加来源: ${url}`);
            updateUI();
            return;
        }
        // 新条目：可信来源直接标记可播放；其余来源状态未知(null)，待验证
        const playable = RELIABLE_SOURCES.has(source) ? true : null;
        capturedUrls.push({ url, normKey, sources: new Set([source]), timestamp: Date.now(), playable });
        console.log(`[m3u8提取][${source}] 捕获: ${url}`);
        // 新捕获时执行 DNS 预解析 + 预连接，加速后续播放
        addDnsPrefetch(url);
        updateUI();
        // 非可信来源（如 Perf）新捕获：做一次轻量验证，确认是否为可播放的 m3u8
        if (playable === null) {
            verifyCapturedUrl(url);
        }
    }

    /** 检查 URL 是否为 ts 分片并反推 */
    function checkTsUrl(url, source) {
        if (!url || typeof url !== 'string') return;
        if (/\.ts(\?|$)/.test(url) && !/\/api\//.test(url)) {
            const m3u8Url = tsUrlToM3u8(url);
            if (m3u8Url) {
                addCaptured(m3u8Url, source);
            }
        }
    }

    /** 通过 GM_xmlhttpRequest 请求 URL 并解析（不受 CORS 限制） */
    function gmFetch(url, source) {
        if (typeof GM_xmlhttpRequest === 'undefined') {
            console.warn('[m3u8提取] GM_xmlhttpRequest 不可用');
            return;
        }
        try {
            GM_xmlhttpRequest({
                method: 'GET',
                url: url,
                headers: {
                    'Referer': location.href,
                    'Origin': location.origin
                },
                onload: function (response) {
                    if (response.status === 200 && response.responseText) {
                        const text = response.responseText;
                        if (text.includes('#EXTM3U') || text.includes('.ts')) {
                            const m3u8Url = getRealVideoSrc(text, url);
                            if (m3u8Url) {
                                addCaptured(m3u8Url, source);
                            }
                        }
                    }
                },
                onerror: function (e) {
                    console.warn('[m3u8提取] GM_xmlhttpRequest失败:', e);
                }
            });
        } catch (e) {
            console.warn('[m3u8提取] gmFetch异常:', e);
        }
    }

    /** 处理 attachments 中的远程视频 URL（优先 GM_xmlhttpRequest，避免 CORS） */
    function processRemoteUrl(remoteUrl, source) {
        if (!remoteUrl) return;

        if (typeof GM_xmlhttpRequest !== 'undefined') {
            GM_xmlhttpRequest({
                method: 'GET',
                url: remoteUrl,
                headers: {
                    'Referer': location.href,
                    'Origin': location.origin
                },
                onload: function (response) {
                    if (response.status === 200 && response.responseText) {
                        const text = response.responseText;
                        const m3u8Url = getRealVideoSrc(text, remoteUrl);
                        if (m3u8Url) {
                            addCaptured(m3u8Url, source);
                            addCaptured(m3u8Url, 'API解密');
                            return;
                        }
                    }
                    // 反推失败，直接添加原始 URL（如果是 m3u8）
                    if (remoteUrl.includes('.m3u8')) {
                        addCaptured(remoteUrl, source);
                        addCaptured(remoteUrl, 'API解密');
                    }
                },
                onerror: function () {
                    // GM 失败时直接添加
                    if (remoteUrl.includes('.m3u8')) {
                        addCaptured(remoteUrl, source);
                    }
                }
            });
        } else if (remoteUrl.includes('.m3u8')) {
            addCaptured(remoteUrl, source);
            addCaptured(remoteUrl, 'API解密');
        }
    }

    /** 处理 attachment API 响应（解密并提取视频 URL） */
    function processAttachmentResponse(responseText, source) {
        if (!responseText) return;
        try {
            const json = JSON.parse(responseText);
            if (!json?.data) return;

            let data = json.data;
            // data 可能是三层 base64 字符串或自定义加密
            if (typeof data === 'string') {
                data = smartDecode(data);
            }
            if (!data) return;

            // 从 attachment 数据中提取视频信息
            const remoteUrl = data?.remoteUrl || data?.remote_url || data?.url;
            if (remoteUrl) {
                processRemoteUrl(remoteUrl, source);
            }

            // 也检查嵌套的 attachments 数组
            const attachments = data?.attachments || [];
            for (const att of attachments) {
                if (att?.category === 'video' && att?.remoteUrl) {
                    processRemoteUrl(att.remoteUrl, source);
                }
            }
        } catch (e) {
            console.warn('[m3u8提取] processAttachmentResponse错误:', e);
        }
    }

    /** 统一响应处理：处理 /api/address/、/api/topic/、/api/attachment 以及 CDN m3u8 响应 */
    function processResponse(url, responseText, source) {
        if (!responseText) return;

        // /api/address/ 响应通常是 m3u8 文本
        if (/\/api\/address\//.test(url)) {
            try {
                if (responseText.includes('#EXTM3U') || responseText.includes('.ts')) {
                    const m3u8Url = getRealVideoSrc(responseText, url);
                    if (m3u8Url) {
                        addCaptured(m3u8Url, source);
                    }
                } else {
                    try {
                        const j = JSON.parse(responseText);
                        if (typeof j?.data === 'string' &&
                            (j.data.includes('#EXTM3U') || j.data.includes('.ts'))) {
                            const m3u8Url = getRealVideoSrc(j.data, url);
                            if (m3u8Url) {
                                addCaptured(m3u8Url, source);
                            }
                        }
                    } catch (_) { /* 非 JSON */ }
                }
            } catch (e) {
                console.warn('[m3u8提取] processResponse address错误:', e);
            }
        }

        // /api/topic/\d+ 响应：JSON.data 可能是三层 base64 / 自定义加密字符串，也可能是对象
        if (/\/api\/topic\/\d+/.test(url)) {
            try {
                let data = null;
                try {
                    const jsonResp = JSON.parse(responseText);
                    if (typeof jsonResp?.data === 'string') {
                        data = smartDecode(jsonResp.data);
                    } else if (jsonResp?.data && typeof jsonResp.data === 'object') {
                        data = jsonResp.data;
                    } else if (typeof jsonResp === 'object' && jsonResp?.attachments) {
                        data = jsonResp;
                    }
                } catch (_) {
                    data = smartDecode(responseText);
                }

                const attachments = data?.attachments || data?.data?.attachments || [];
                for (const att of attachments) {
                    if (att?.category === 'video' && att?.remoteUrl) {
                        processRemoteUrl(att.remoteUrl, source);
                    }
                }
            } catch (e) {
                console.warn('[m3u8提取] processResponse topic错误:', e);
            }
        }

        // /api/attachment 响应
        if (/\/api\/attachment/.test(url)) {
            processAttachmentResponse(responseText, source);
        }

        // 非 API 的 CDN m3u8 响应（hls.js 播放器加载的 m3u8 文件）
        if (!/\/api\//.test(url) && /\.m3u8(\?|$)/.test(url)) {
            try {
                if (responseText.includes('#EXTM3U') || responseText.includes('.ts')) {
                    const m3u8Url = getRealVideoSrc(responseText, url);
                    if (m3u8Url) {
                        addCaptured(m3u8Url, source);
                    }
                }
            } catch (e) {
                console.warn('[m3u8提取] processResponse CDN m3u8错误:', e);
            }
        }

        // 通用：任何 JSON 响应中尝试提取 m3u8 URL
        if (/\/api\//.test(url)) {
            try {
                const matches = responseText.match(/https?:\/\/[^\s"'\\]+\.m3u8[^\s"'\\]*/g);
                if (matches) {
                    for (const m of matches) {
                        addCaptured(m, source);
                    }
                }
            } catch (_) { /* ignore */ }
        }
    }

    // ========== 通道1: XHR Hook（原型方法替换，兼容性更好） ==========
    function installXHRHook() {
        const win = unsafeWindow || window;
        const origOpen = win.XMLHttpRequest.prototype.open;
        const origSend = win.XMLHttpRequest.prototype.send;

        win.XMLHttpRequest.prototype.open = function (method, url, ...args) {
            this._hjUrl = url;
            return origOpen.apply(this, [method, url, ...args]);
        };

        win.XMLHttpRequest.prototype.send = function (...args) {
            this.addEventListener('load', function () {
                try {
                    const url = this._hjUrl || '';
                    const responseText = this.responseText || this.response || '';
                    processResponse(url, responseText, 'XHR Hook');
                    checkTsUrl(url, 'TS反推');
                } catch (e) {
                    console.warn('[m3u8提取] XHR处理错误:', e);
                }
            });
            return origSend.apply(this, args);
        };

        console.log('[m3u8提取] XHR Hook 已安装');
    }

    // ========== 通道2: Fetch Hook ==========
    function installFetchHook() {
        const win = unsafeWindow || window;
        if (typeof win.fetch !== 'function') return;
        const origFetch = win.fetch.bind(win);

        const hookedFetch = function (input, init) {
            const url = (typeof input === 'string') ? input : (input?.url || '');

            return origFetch(input, init).then(response => {
                try {
                    const cloned = response.clone();
                    (async () => {
                        try {
                            if (/\/api\/address\//.test(url) ||
                                /\/api\/topic\/\d+/.test(url) ||
                                /\/api\/attachment/.test(url)) {
                                const text = await cloned.text();
                                processResponse(url, text, 'Fetch Hook');
                            }
                            if (/\.ts(\?|$)/.test(url)) {
                                checkTsUrl(url, 'TS反推');
                            }
                            // CDN m3u8
                            if (!/\/api\//.test(url) && /\.m3u8(\?|$)/.test(url)) {
                                const text = await cloned.text();
                                processResponse(url, text, 'Fetch Hook');
                            }
                        } catch (e) {
                            console.warn('[m3u8提取] Fetch异步处理错误:', e);
                        }
                    })();
                } catch (e) {
                    console.warn('[m3u8提取] Fetch hook处理错误:', e);
                }
                return response;
            });
        };

        try {
            Object.defineProperty(win, 'fetch', {
                value: hookedFetch,
                writable: true,
                configurable: true
            });
        } catch (e) {
            win.fetch = hookedFetch;
        }

        console.log('[m3u8提取] Fetch Hook 已安装');
    }

    // ========== 通道3: DOM 视频源监控 ==========
    function installDOMObserver() {
        const checkVideoSrc = (src) => {
            if (!src) return;
            if (src.includes('.m3u8') && !/\/api\//.test(src)) {
                addCaptured(src, 'DOM监控');
            } else if (/\.ts(\?|$)/.test(src) && !/\/api\//.test(src)) {
                const m3u8Url = tsUrlToM3u8(src);
                if (m3u8Url) addCaptured(m3u8Url, 'DOM监控');
            }
        };

        const scanElement = (el) => {
            if (el.tagName === 'VIDEO' || el.tagName === 'SOURCE') {
                checkVideoSrc(el.src);
                checkVideoSrc(el.getAttribute('src'));
            }
            if (el.querySelectorAll) {
                const targets = el.querySelectorAll('video, source');
                for (const t of targets) {
                    checkVideoSrc(t.src);
                    checkVideoSrc(t.getAttribute('src'));
                }
            }
        };

        const observer = new MutationObserver((mutations) => {
            for (const mutation of mutations) {
                for (const node of mutation.addedNodes) {
                    if (node.nodeType === 1) scanElement(node);
                }
                if (mutation.type === 'attributes' && mutation.attributeName === 'src') {
                    checkVideoSrc(mutation.target.src);
                    checkVideoSrc(mutation.target.getAttribute('src'));
                }
            }
        });

        const startObserving = () => {
            observer.observe(document.documentElement, {
                childList: true,
                subtree: true,
                attributes: true,
                attributeFilter: ['src']
            });
            console.log('[m3u8提取] DOM Observer 已启动');
        };

        if (document.documentElement) {
            startObserving();
        } else {
            document.addEventListener('DOMContentLoaded', startObserving);
        }
    }

    // ========== 通道4: Performance API 监控 ==========
    /** Perf 通道节流表：标准化 URL -> 上次处理时间戳，同一 URL 30 秒内只处理一次 */
    const perfThrottleMap = new Map();
    const PERF_THROTTLE_MS = 30000;
    function installPerformanceObserver() {
        try {
            const perfObserver = new PerformanceObserver((list) => {
                for (const entry of list.getEntries()) {
                    const name = entry.name || '';
                    if (!name) continue;

                    if (/\/api\/address\//.test(name)) {
                        gmFetch(name, 'Performance API');
                        continue;
                    }
                    if (/\/api\/topic\/\d+/.test(name)) {
                        continue;
                    }

                    const isM3u8 = name.includes('.m3u8') && !/\/api\//.test(name);
                    const isTs = /\.ts(\?|$)/.test(name) && !/\/api\//.test(name);
                    if (!isM3u8 && !isTs) continue;

                    // Perf 通道限流：把 m3u8 / ts 反推后的 m3u8 归一化后判重，
                    // 同一标准化 URL 在 30 秒内只处理一次，避免同一视频的多次网络请求
                    // （尤其 ts 分片会反推出同一个 m3u8）被反复当作新结果处理。
                    const targetUrl = isM3u8 ? name : tsUrlToM3u8(name);
                    if (!targetUrl) continue;
                    // 二次校验：Perf 通道最终加入列表的必须是 .m3u8 地址，
                    // 绝不把 .ts 分片地址当作可播放条目（.ts 反推失败会返回空串已被上面拦截）。
                    if (!/\.m3u8(\?|$)/i.test(targetUrl)) continue;
                    const normKey = normalizeM3u8Url(targetUrl);
                    const now = Date.now();
                    const last = perfThrottleMap.get(normKey);
                    if (last && (now - last) < PERF_THROTTLE_MS) continue; // 节流窗口内，跳过
                    perfThrottleMap.set(normKey, now);

                    // addCaptured 内部按标准化 URL 去重：若该 URL 已被其他通道捕获，
                    // 此处只会合并 Perf 标签，不会新增条目。
                    addCaptured(targetUrl, 'Performance API');
                }
            });

            perfObserver.observe({ type: 'resource', buffered: true });
            console.log('[m3u8提取] Performance Observer 已启动');
        } catch (e) {
            console.warn('[m3u8提取] Performance Observer 不可用:', e);
        }
    }

    // ========== 通道5: hls.js / 播放器实例劫持 ==========
    function installPlayerHijack() {
        const scan = () => {
            const videos = document.querySelectorAll('video');
            for (const video of videos) {
                const hls = video.__hls || video.hls || video._hls;
                if (hls?.url) {
                    addCaptured(hls.url, '播放器劫持');
                }
                if (video.src?.includes('.m3u8') && !video.src.startsWith('blob:')) {
                    addCaptured(video.src, '播放器劫持');
                }
                if (video.currentSrc?.includes('.m3u8') && !video.currentSrc.startsWith('blob:')) {
                    addCaptured(video.currentSrc, '播放器劫持');
                }
            }
        };

        const hookHlsConstructor = () => {
            const win = unsafeWindow || window;
            if (!win.Hls || win.Hls.__hjHijacked) return;

            const OrigHls = win.Hls;

            // 使用 Proxy 代替构造函数替换，保留所有静态属性和方法
            try {
                win.Hls = new Proxy(OrigHls, {
                    construct(target, args) {
                        const instance = new target(...args);
                        try {
                            if (OrigHls.Events?.MANIFEST_PARSED) {
                                instance.on(OrigHls.Events.MANIFEST_PARSED, () => {
                                    if (instance.url) {
                                        addCaptured(instance.url, '播放器劫持');
                                    }
                                });
                            }
                            const origLoadSource = instance.loadSource;
                            if (typeof origLoadSource === 'function') {
                                instance.loadSource = function (url) {
                                    if (url?.includes?.('.m3u8')) {
                                        addCaptured(url, '播放器劫持');
                                    }
                                    return origLoadSource.apply(this, arguments);
                                };
                            }
                        } catch (e) {
                            console.warn('[m3u8提取] Hls实例监听失败:', e);
                        }
                        return instance;
                    },
                    get(target, prop) {
                        return target[prop];
                    }
                });
                win.Hls.__hjHijacked = true;
            } catch (e) {
                console.warn('[m3u8提取] Hls Proxy 安装失败:', e);
            }
        };

        let scanCount = 0;
        const maxScans = 15;
        const startScanning = () => {
            hookHlsConstructor();
            const timer = setInterval(() => {
                hookHlsConstructor();
                scan();
                scanCount++;
                if (scanCount >= maxScans) clearInterval(timer);
            }, 2000);
        };

        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', startScanning);
        } else {
            startScanning();
        }
        console.log('[m3u8提取] 播放器劫持 已安装');
    }

    // ========== 通道6: MediaSource Hook ==========
    function installMSEHook() {
        const win = unsafeWindow || window;
        if (!win.MediaSource) {
            console.warn('[m3u8提取] MediaSource不可用');
            return;
        }
        try {
            const origAddSB = win.MediaSource.prototype.addSourceBuffer;
            win.MediaSource.prototype.addSourceBuffer = function (mimeType) {
                console.log('[m3u8提取][MSE] addSourceBuffer:', mimeType);
                try {
                    setTimeout(() => {
                        const videos = document.querySelectorAll('video');
                        for (const video of videos) {
                            const hls = video.__hls || video.hls || video._hls;
                            if (hls?.url) {
                                addCaptured(hls.url, 'MSE监控');
                            }
                            if (video.src?.includes('.m3u8') && !video.src.startsWith('blob:')) {
                                addCaptured(video.src, 'MSE监控');
                            }
                            if (video.currentSrc?.includes('.m3u8') && !video.currentSrc.startsWith('blob:')) {
                                addCaptured(video.currentSrc, 'MSE监控');
                            }
                        }
                    }, 100);
                } catch (e) { /* ignore */ }
                return origAddSB.apply(this, arguments);
            };
            console.log('[m3u8提取] MSE监控 已安装');
        } catch (e) {
            console.warn('[m3u8提取] MSE Hook 安装失败:', e);
        }
    }

    // ========== 通道7: URL.createObjectURL Hook ==========
    function installBlobHook() {
        const win = unsafeWindow || window;
        if (!win.URL || typeof win.URL.createObjectURL !== 'function') return;
        try {
            const origCreateObjectURL = win.URL.createObjectURL;
            win.URL.createObjectURL = function (obj) {
                const blobUrl = origCreateObjectURL.apply(this, arguments);
                try {
                    if (obj instanceof Blob && obj.type?.includes('mpegurl')) {
                        const reader = new FileReader();
                        reader.onload = () => {
                            try {
                                const text = reader.result;
                                if (text && (text.includes('#EXTM3U') || text.includes('.m3u8'))) {
                                    const urlMatch = text.match(/https?:\/\/[^\s"']+\.m3u8[^\s"']*/);
                                    if (urlMatch) {
                                        addCaptured(urlMatch[0], 'Blob捕获');
                                    }
                                    const realUrl = getRealVideoSrc(text, '');
                                    if (realUrl) {
                                        addCaptured(realUrl, 'Blob捕获');
                                    }
                                }
                            } catch (e) { /* ignore */ }
                        };
                        try { reader.readAsText(obj); } catch (e) { /* ignore */ }
                    }
                } catch (e) { /* ignore */ }
                return blobUrl;
            };
            console.log('[m3u8提取] Blob捕获 已安装');
        } catch (e) {
            console.warn('[m3u8提取] Blob Hook 安装失败:', e);
        }
    }

    // ========== 通道8: Storage 扫描 + Hook ==========
    function installStorageMonitor() {
        const win = unsafeWindow || window;

        const checkValue = (value, source) => {
            if (!value || typeof value !== 'string') return;
            const matches = value.match(/https?:\/\/[^\s"'\\]+\.m3u8[^\s"'\\]*/g);
            if (matches) {
                for (const url of matches) {
                    addCaptured(url, source);
                }
            }
        };

        try {
            const origSetLocal = win.localStorage.setItem.bind(win.localStorage);
            win.localStorage.setItem = function (key, value) {
                checkValue(value, '存储扫描');
                return origSetLocal(key, value);
            };
        } catch (e) {
            console.warn('[m3u8提取] localStorage hook失败:', e);
        }

        try {
            const origSetSession = win.sessionStorage.setItem.bind(win.sessionStorage);
            win.sessionStorage.setItem = function (key, value) {
                checkValue(value, '存储扫描');
                return origSetSession(key, value);
            };
        } catch (e) {
            console.warn('[m3u8提取] sessionStorage hook失败:', e);
        }

        const scanStorage = () => {
            try {
                for (let i = 0; i < localStorage.length; i++) {
                    const key = localStorage.key(i);
                    checkValue(localStorage.getItem(key), '存储扫描');
                }
                for (let i = 0; i < sessionStorage.length; i++) {
                    const key = sessionStorage.key(i);
                    checkValue(sessionStorage.getItem(key), '存储扫描');
                }
            } catch (e) {
                console.warn('[m3u8提取] 存储初始扫描失败:', e);
            }
        };

        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', () => setTimeout(scanStorage, 500));
        } else {
            setTimeout(scanStorage, 1000);
        }
        console.log('[m3u8提取] 存储扫描 已安装');
    }

    // ========== 通道9: WebSocket Hook ==========
    function installWebSocketHook() {
        const win = unsafeWindow || window;
        if (!win.WebSocket) return;
        try {
            const OrigWS = win.WebSocket;
            const HookedWS = function (url, protocols) {
                const ws = protocols !== undefined ? new OrigWS(url, protocols) : new OrigWS(url);

                try {
                    if (typeof url === 'string') {
                        const matches = url.match(/https?:\/\/[^\s"'\\]+\.m3u8[^\s"'\\]*/g);
                        if (matches) {
                            for (const m of matches) addCaptured(m, 'WebSocket');
                        }
                    }
                } catch (e) { /* ignore */ }

                const messageHandler = (event) => {
                    try {
                        const data = typeof event.data === 'string' ? event.data : '';
                        if (data) {
                            const matches = data.match(/https?:\/\/[^\s"'\\]+\.m3u8[^\s"'\\]*/g);
                            if (matches) {
                                for (const m3u8Url of matches) {
                                    addCaptured(m3u8Url, 'WebSocket');
                                }
                            }
                        }
                    } catch (e) {
                        console.warn('[m3u8提取] WebSocket消息处理错误:', e);
                    }
                };

                try {
                    ws.addEventListener('message', messageHandler);
                } catch (e) { /* ignore */ }
                return ws;
            };
            try {
                HookedWS.prototype = OrigWS.prototype;
                HookedWS.CONNECTING = OrigWS.CONNECTING;
                HookedWS.OPEN = OrigWS.OPEN;
                HookedWS.CLOSING = OrigWS.CLOSING;
                HookedWS.CLOSED = OrigWS.CLOSED;
            } catch (e) { /* ignore */ }
            win.WebSocket = HookedWS;
            console.log('[m3u8提取] WebSocket Hook 已安装');
        } catch (e) {
            console.warn('[m3u8提取] WebSocket Hook 安装失败:', e);
        }
    }

    // ========== SPA 路由变化检测 ==========
    function installRouteWatcher() {
        // 防止重复注册 pushState/popstate 监听器导致内存泄漏
        if (installRouteWatcher.__installed) return;
        installRouteWatcher.__installed = true;

        let lastPath = location.pathname + location.search;

        const checkRoute = () => {
            const newPath = location.pathname + location.search;
            if (newPath !== lastPath) {
                lastPath = newPath;
                capturedUrls = [];
                updateUI();
                // 路由变化时彻底销毁播放器实例，避免内存泄漏
                try {
                    if (typeof closePlayer === 'function' &&
                        playerOverlay && playerOverlay.classList.contains('visible')) {
                        closePlayer();
                    }
                    if (hlsInstance) { hlsInstance.destroy(); hlsInstance = null; }
                    if (typeof destroyPreload === 'function') destroyPreload();
                } catch (e) { /* ignore */ }
                console.log('[m3u8提取] 路由变化，已重置捕获列表并销毁播放器');
            }
        };

        window.addEventListener('popstate', checkRoute);

        const win = unsafeWindow || window;
        const origPush = win.history.pushState;
        const origReplace = win.history.replaceState;

        win.history.pushState = function (...args) {
            origPush.apply(this, args);
            checkRoute();
        };
        win.history.replaceState = function (...args) {
            origReplace.apply(this, args);
            checkRoute();
        };
    }

    // ========== 广告拦截（CSS + XHR + window.open） ==========
    function installAdBlocker() {
        const adCss = `
            .luodiconfirm,
            .van-dialog.luodiconfirm,
            .van-dialog[class*="luodi"],
            div[role="dialog"][class*="luodi"],
            .luodi_ye_box,
            div[aria-labelledby*="重要提示"],
            .newconfirm,
            .van-dialog.newconfirm,
            [class*="newconfirm"],
            div[aria-labelledby*="您还不是会员"],
            div[aria-labelledby*="开通会员即可免除站内广告"],
            .custom_carousel,
            img[data-id^="banner_"],
            #timeCount,
            .ad-container,
            [class*="ad-box"],
            aside .el-carousel,
            .sidebar-ad,
            .prompttext,
            .containeradvertising,
            .bannerliststyle,
            .addbox,
            [class*="addbox"],
            .topbanmer,
            [class*="topbanmer"],
            .my-swipe,
            .crossbutton,
            .van-overlay,
            .van-popup--center,
            iframe[src*="ad"],
            iframe[src*="banner"],
            [id*="google_ads"],
            [class*="sponsor"] {
                display: none !important;
                opacity: 0 !important;
                pointer-events: none !important;
                z-index: -1000 !important;
            }
            html.van-overflow-hidden,
            body.van-overflow-hidden,
            html.el-popup-parent--hidden,
            body.el-popup-parent--hidden {
                overflow: auto !important;
                overflow-y: auto !important;
            }
        `;
        const style = document.createElement('style');
        style.textContent = adCss;
        const target = document.head || document.documentElement;
        if (target) {
            target.appendChild(style);
        } else {
            document.addEventListener('DOMContentLoaded', () => {
                (document.head || document.documentElement).appendChild(style);
            });
        }

        // 拦截广告相关的 window.open
        const win = unsafeWindow || window;
        const origOpen = win.open;
        win.open = function (url, ...args) {
            if (url && typeof url === 'string') {
                const adPatterns = /ad[s]?[\.\-\/]|banner|click\.php|track(ing)?|pop(up|under)/i;
                if (adPatterns.test(url)) {
                    console.log('[m3u8提取] 已拦截广告弹窗:', url);
                    return null;
                }
            }
            return origOpen.apply(this, [url, ...args]);
        };

        console.log('[m3u8提取] 广告拦截 已安装');
    }

    // ========== 反调试绕过 ==========
    function installAntiDebugBypass() {
        const win = unsafeWindow || window;

        // 拦截 Function.prototype.constructor 中的 debugger
        try {
            const origConstructor = win.Function.prototype.constructor;
            win.Function.prototype.constructor = function (...args) {
                if (args.length > 0 && typeof args[0] === 'string' && args[0].includes('debugger')) {
                    return function () {};
                }
                return origConstructor.apply(this, args);
            };
        } catch (e) { /* ignore */ }

        // 拦截 setInterval 中的 debugger 检测
        try {
            const origSetInterval = win.setInterval;
            win.setInterval = function (fn, delay, ...args) {
                if (typeof fn === 'function' && delay < 2000) {
                    try {
                        const fnStr = fn.toString();
                        if (fnStr.includes('debugger') || fnStr.includes('devtools')) {
                            console.log('[m3u8提取] 已拦截 setInterval debugger 检测');
                            return 0;
                        }
                    } catch (e) { /* ignore */ }
                }
                if (typeof fn === 'string' && fn.includes('debugger')) {
                    return 0;
                }
                return origSetInterval.apply(this, [fn, delay, ...args]);
            };
        } catch (e) { /* ignore */ }

        // 拦截 eval 中的 debugger
        try {
            const origEval = win.eval;
            win.eval = function (code) {
                if (typeof code === 'string' && code.includes('debugger')) {
                    code = code.replace(/debugger\s*;?/g, '');
                }
                return origEval.call(this, code);
            };
        } catch (e) { /* ignore */ }

        // 伪装 DevTools 窗口尺寸（防止 outerWidth/innerWidth 检测）
        try {
            Object.defineProperty(win, 'outerWidth', {
                get: () => win.innerWidth,
                configurable: true
            });
            Object.defineProperty(win, 'outerHeight', {
                get: () => win.innerHeight,
                configurable: true
            });
        } catch (e) { /* ignore */ }

        console.log('[m3u8提取] 反调试绕过 已安装');
    }

    // ========== 自动展开帖子内容 ==========
    function installAutoExpand() {
        const expandContent = () => {
            // 移除内容截断的 max-height
            document.querySelectorAll(
                '[class*="collapse"], [class*="truncate"], [class*="ellipsis"], ' +
                '[class*="text-clamp"], [style*="max-height"]'
            ).forEach(el => {
                if (el.closest('#hjm3u8-panel') || el.closest('#hjm3u8-player-overlay')) return;
                el.style.maxHeight = 'none';
                el.style.overflow = 'visible';
                el.style.webkitLineClamp = 'unset';
            });

            // 自动点击"查看更多"/"展开"按钮
            document.querySelectorAll(
                '.show-more-btn, .expand-btn, [class*="show-more"], [class*="expand"], ' +
                '[class*="read-more"], [class*="view-all"]'
            ).forEach(btn => {
                if (btn.closest('#hjm3u8-panel') || btn.closest('#hjm3u8-player-overlay')) return;
                if (!btn._hjClicked) {
                    btn._hjClicked = true;
                    try { btn.click(); } catch (e) { /* ignore */ }
                }
            });
        };

        // 初始执行 + MutationObserver 持续监控
        const startAutoExpand = () => {
            expandContent();
            const observer = new MutationObserver(() => {
                expandContent();
            });
            observer.observe(document.body, { childList: true, subtree: true });
        };

        if (document.body) {
            startAutoExpand();
        } else {
            document.addEventListener('DOMContentLoaded', startAutoExpand);
        }
        console.log('[m3u8提取] 自动展开 已安装');
    }

    // ========== UI 组件 ==========
    let floatBtn = null;
    let panel = null;
    let toastEl = null;

    function injectStyles() {
        GM_addStyle(`
            /* ===== 悬浮按钮 ===== */
            #hjm3u8-float-btn {
                position: fixed;
                bottom: 30px;
                right: 30px;
                width: 52px;
                height: 52px;
                border-radius: 50%;
                background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                color: #fff;
                font-size: 22px;
                display: flex;
                align-items: center;
                justify-content: center;
                cursor: grab;
                z-index: 2147483647;
                box-shadow: 0 4px 15px rgba(102, 126, 234, 0.4);
                transition: transform 0.3s ease, box-shadow 0.3s ease, background 0.3s ease;
                user-select: none;
                border: none;
                outline: none;
                touch-action: none;
            }
            #hjm3u8-float-btn:hover {
                transform: scale(1.1);
                box-shadow: 0 6px 20px rgba(102, 126, 234, 0.6);
            }
            #hjm3u8-float-btn.has-capture {
                background: linear-gradient(135deg, #43e97b 0%, #38f9d7 100%);
                box-shadow: 0 4px 15px rgba(67, 233, 123, 0.4);
                animation: hjm3u8-pulse 2s ease-in-out infinite;
            }
            #hjm3u8-float-btn.has-capture:hover {
                box-shadow: 0 6px 20px rgba(67, 233, 123, 0.6);
            }
            #hjm3u8-float-btn.dragging {
                cursor: grabbing;
                transition: none;
                transform: scale(1.05);
            }

            @keyframes hjm3u8-pulse {
                0%, 100% { box-shadow: 0 4px 15px rgba(67, 233, 123, 0.4); }
                50%       { box-shadow: 0 4px 25px rgba(67, 233, 123, 0.7); }
            }

            /* ===== 面板 ===== */
            #hjm3u8-panel {
                position: fixed;
                bottom: 95px;
                right: 30px;
                width: 440px;
                max-height: 520px;
                background: rgba(20, 20, 30, 0.96);
                backdrop-filter: blur(16px);
                -webkit-backdrop-filter: blur(16px);
                border-radius: 16px;
                border: 1px solid rgba(255, 255, 255, 0.1);
                box-shadow: 0 20px 60px rgba(0, 0, 0, 0.5);
                z-index: 2147483646;
                display: none;
                flex-direction: column;
                overflow: hidden;
                font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                animation: hjm3u8-slideUp 0.25s ease-out;
            }
            @keyframes hjm3u8-slideUp {
                from { opacity: 0; transform: translateY(12px); }
                to   { opacity: 1; transform: translateY(0); }
            }
            #hjm3u8-panel.visible {
                display: flex;
            }
            #hjm3u8-panel-header {
                display: flex;
                align-items: center;
                justify-content: space-between;
                padding: 16px 20px;
                border-bottom: 1px solid rgba(255, 255, 255, 0.08);
            }
            #hjm3u8-panel-header h3 {
                margin: 0;
                font-size: 15px;
                font-weight: 600;
                color: #fff;
                display: flex;
                align-items: center;
                gap: 8px;
            }
            #hjm3u8-panel-header h3 .hj-count-badge {
                background: rgba(99, 179, 237, 0.2);
                color: #63b3ed;
                padding: 2px 8px;
                border-radius: 10px;
                font-size: 12px;
            }
            #hjm3u8-panel-close {
                width: 28px;
                height: 28px;
                border-radius: 50%;
                background: rgba(255, 255, 255, 0.1);
                border: none;
                color: #aaa;
                font-size: 16px;
                cursor: pointer;
                display: flex;
                align-items: center;
                justify-content: center;
                transition: all 0.2s;
            }
            #hjm3u8-panel-close:hover {
                background: rgba(255, 80, 80, 0.3);
                color: #ff5050;
            }
            #hjm3u8-panel-body {
                flex: 1;
                overflow-y: auto;
                padding: 12px 16px;
            }
            #hjm3u8-panel-body::-webkit-scrollbar {
                width: 4px;
            }
            #hjm3u8-panel-body::-webkit-scrollbar-thumb {
                background: rgba(255,255,255,0.2);
                border-radius: 2px;
            }

            /* ===== 列表项 ===== */
            .hjm3u8-item {
                display: flex;
                align-items: center;
                gap: 10px;
                padding: 10px 12px;
                margin-bottom: 8px;
                background: rgba(255, 255, 255, 0.04);
                border-radius: 10px;
                border: 1px solid rgba(255, 255, 255, 0.06);
                transition: background 0.2s;
            }
            .hjm3u8-item:hover {
                background: rgba(255, 255, 255, 0.08);
            }
            /* 不可用条目：降低视觉优先级 */
            .hjm3u8-item.unplayable {
                opacity: 0.5;
            }
            .hjm3u8-item.unplayable:hover {
                opacity: 0.75;
            }
            /* 可播放状态图标 */
            .hjm3u8-status {
                flex-shrink: 0;
                display: inline-flex;
                align-items: center;
                font-size: 12px;
                font-weight: 700;
                line-height: 1;
            }
            .hjm3u8-status.ok { color: #48bb78; }
            .hjm3u8-status.warn { color: #f6ad55; }
            .hjm3u8-status.pending { color: #94a3b8; }
            /* 重试验证按钮 */
            .hjm3u8-retry-btn {
                flex-shrink: 0;
                padding: 5px 8px;
                border-radius: 6px;
                border: 1px solid rgba(246, 173, 85, 0.5);
                background: rgba(246, 173, 85, 0.15);
                color: #f6ad55;
                font-size: 11px;
                cursor: pointer;
            }
            .hjm3u8-badges {
                flex-shrink: 0;
                display: flex;
                flex-wrap: wrap;
                gap: 3px;
                max-width: 120px;
            }
            .hjm3u8-badge {
                flex-shrink: 0;
                padding: 3px 8px;
                border-radius: 6px;
                font-size: 11px;
                font-weight: 600;
                white-space: nowrap;
            }
            .hjm3u8-badge.xhr { background: rgba(99, 179, 237, 0.2); color: #63b3ed; }
            .hjm3u8-badge.fetch { background: rgba(183, 148, 244, 0.2); color: #b794f4; }
            .hjm3u8-badge.ts { background: rgba(246, 173, 85, 0.2); color: #f6ad55; }
            .hjm3u8-badge.dom { background: rgba(72, 187, 120, 0.2); color: #48bb78; }
            .hjm3u8-badge.perf { background: rgba(237, 100, 166, 0.2); color: #ed64a6; }
            .hjm3u8-badge.api { background: rgba(236, 201, 75, 0.2); color: #ecc94b; }
            .hjm3u8-badge.player { background: rgba(56, 178, 172, 0.2); color: #38b2ac; }
            .hjm3u8-badge.mse { background: rgba(99, 102, 241, 0.2); color: #6366f1; }
            .hjm3u8-badge.blob { background: rgba(148, 163, 184, 0.2); color: #94a3b8; }
            .hjm3u8-badge.storage { background: rgba(251, 146, 60, 0.2); color: #fb923c; }
            .hjm3u8-badge.ws { background: rgba(34, 197, 94, 0.2); color: #22c55e; }
            .hjm3u8-url {
                flex: 1;
                font-size: 12px;
                color: #cbd5e0;
                overflow: hidden;
                text-overflow: ellipsis;
                white-space: nowrap;
                font-family: 'SF Mono', Monaco, 'Cascadia Code', monospace;
            }
            .hjm3u8-actions {
                flex-shrink: 0;
                display: flex;
                gap: 4px;
            }
            .hjm3u8-copy-btn,
            .hjm3u8-dl-btn {
                flex-shrink: 0;
                padding: 5px 8px;
                border-radius: 6px;
                border: 1px solid;
                font-size: 11px;
                cursor: pointer;
                transition: all 0.2s;
                white-space: nowrap;
            }
            .hjm3u8-copy-btn {
                background: rgba(99, 179, 237, 0.15);
                border-color: rgba(99, 179, 237, 0.3);
                color: #63b3ed;
            }
            .hjm3u8-copy-btn:hover {
                background: rgba(99, 179, 237, 0.3);
            }
            .hjm3u8-dl-btn {
                background: rgba(72, 187, 120, 0.15);
                border-color: rgba(72, 187, 120, 0.3);
                color: #48bb78;
            }
            .hjm3u8-dl-btn:hover {
                background: rgba(72, 187, 120, 0.3);
            }

            /* ===== 底部 ===== */
            #hjm3u8-panel-footer {
                padding: 12px 16px;
                border-top: 1px solid rgba(255, 255, 255, 0.08);
                display: flex;
                gap: 8px;
            }
            #hjm3u8-copy-all {
                flex: 1;
                padding: 10px;
                border-radius: 8px;
                background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                border: none;
                color: #fff;
                font-size: 13px;
                font-weight: 600;
                cursor: pointer;
                transition: opacity 0.2s;
            }
            #hjm3u8-copy-all:hover {
                opacity: 0.85;
            }
            #hjm3u8-play-first {
                flex: 1;
                padding: 10px;
                border-radius: 8px;
                background: linear-gradient(135deg, #b794f4 0%, #805ad5 100%);
                border: none;
                color: #fff;
                font-size: 13px;
                font-weight: 600;
                cursor: pointer;
                transition: opacity 0.2s;
            }
            #hjm3u8-play-first:hover {
                opacity: 0.85;
            }
            #hjm3u8-dl-all {
                flex: 1;
                padding: 10px;
                border-radius: 8px;
                background: linear-gradient(135deg, #43e97b 0%, #38f9d7 100%);
                border: none;
                color: #1a1a2e;
                font-size: 13px;
                font-weight: 600;
                cursor: pointer;
                transition: opacity 0.2s;
            }
            #hjm3u8-dl-all:hover {
                opacity: 0.85;
            }
            .hjm3u8-empty {
                text-align: center;
                color: #666;
                padding: 40px 20px;
                font-size: 13px;
                line-height: 1.8;
            }
            .hjm3u8-empty .hj-tip {
                font-size: 11px;
                color: #555;
                margin-top: 12px;
            }

            /* ===== 内置播放器 ===== */
            #hjm3u8-player-overlay {
                position: fixed;
                top: 0; left: 0; right: 0; bottom: 0;
                background: rgba(0, 0, 0, 0.92);
                z-index: 2147483647;
                display: none;
                justify-content: center;
                align-items: center;
                backdrop-filter: blur(8px);
                -webkit-backdrop-filter: blur(8px);
            }
            #hjm3u8-player-overlay.visible {
                display: flex;
            }
            #hjm3u8-player-container {
                position: relative;
                width: 90vw;
                max-width: 1000px;
                max-height: 85vh;
                border-radius: 12px;
                overflow: hidden;
                box-shadow: 0 20px 80px rgba(0,0,0,0.8);
                background: #000;
            }
            #hjm3u8-player-video {
                width: 100%;
                max-height: 85vh;
                display: block;
                outline: none;
                cursor: pointer;
            }
            #hjm3u8-player-close {
                position: absolute;
                top: 12px;
                right: 12px;
                width: 36px;
                height: 36px;
                border-radius: 50%;
                background: rgba(0,0,0,0.6);
                border: 1px solid rgba(255,255,255,0.2);
                color: #fff;
                font-size: 18px;
                cursor: pointer;
                display: flex;
                align-items: center;
                justify-content: center;
                z-index: 20;
                transition: all 0.2s;
            }
            #hjm3u8-player-close:hover {
                background: rgba(255, 80, 80, 0.6);
            }

            /* ===== 自定义控制栏 ===== */
            #hjm3u8-player-controls {
                position: absolute;
                bottom: 0;
                left: 0;
                right: 0;
                background: linear-gradient(transparent, rgba(10, 10, 15, 0.85) 30%, rgba(10, 10, 15, 0.95));
                padding: 10px 16px 14px 16px;
                display: flex;
                flex-direction: column;
                gap: 8px;
                z-index: 15;
                transition: opacity 0.3s, transform 0.3s;
                opacity: 0;
                transform: translateY(5px);
                pointer-events: auto;
            }
            #hjm3u8-player-container.show-controls #hjm3u8-player-controls {
                opacity: 1;
                transform: translateY(0);
            }

            /* ===== 进度条 ===== */
            #hjm3u8-progress-container {
                width: 100%;
                height: 14px;
                display: flex;
                align-items: center;
                cursor: pointer;
            }
            #hjm3u8-progress-bar {
                width: 100%;
                height: 4px;
                background: rgba(255, 255, 255, 0.2);
                border-radius: 2px;
                position: relative;
                transition: height 0.1s;
            }
            #hjm3u8-progress-container:hover #hjm3u8-progress-bar {
                height: 6px;
            }
            #hjm3u8-buffer-bar {
                position: absolute;
                left: 0; top: 0; bottom: 0;
                width: 0;
                background: rgba(255, 255, 255, 0.35);
                border-radius: 2px;
            }
            #hjm3u8-play-bar {
                position: absolute;
                left: 0; top: 0; bottom: 0;
                width: 0;
                background: #63b3ed;
                border-radius: 2px;
            }
            #hjm3u8-progress-handle {
                position: absolute;
                top: 50%;
                left: 0;
                width: 12px;
                height: 12px;
                border-radius: 50%;
                background: #fff;
                box-shadow: 0 0 5px rgba(0,0,0,0.5);
                transform: translate(-50%, -50%) scale(0);
                transition: transform 0.1s;
            }
            #hjm3u8-progress-container:hover #hjm3u8-progress-handle {
                transform: translate(-50%, -50%) scale(1);
            }

            /* ===== 按钮栏 ===== */
            #hjm3u8-controls-buttons {
                display: flex;
                align-items: center;
                justify-content: space-between;
                width: 100%;
            }
            .hjm3u8-controls-left, .hjm3u8-controls-right {
                display: flex;
                align-items: center;
                gap: 12px;
            }
            .hjm3u8-cbtn {
                background: transparent;
                border: none;
                color: #fff;
                font-size: 14px;
                cursor: pointer;
                padding: 4px 8px;
                border-radius: 4px;
                transition: background 0.2s, color 0.2s;
                font-family: inherit;
                font-weight: 500;
                display: flex;
                align-items: center;
                justify-content: center;
            }
            .hjm3u8-cbtn:hover {
                background: rgba(255, 255, 255, 0.12);
                color: #63b3ed;
            }
            .hjm3u8-cbtn:disabled {
                opacity: 0.35;
                cursor: not-allowed;
            }
            #hjm3u8-time-display {
                color: #ccc;
                font-size: 12px;
                font-family: monospace;
                user-select: none;
            }
            #hjm3u8-speed-display {
                position: absolute;
                top: 50%;
                left: 50%;
                transform: translate(-50%, -50%);
                background: rgba(0,0,0,0.7);
                color: #fff;
                padding: 8px 20px;
                border-radius: 20px;
                font-size: 16px;
                font-weight: bold;
                pointer-events: none;
                opacity: 0;
                transition: opacity 0.3s;
                z-index: 5;
            }
            #hjm3u8-speed-display.visible {
                opacity: 1;
            }
            #hjm3u8-player-info {
                position: absolute;
                top: 12px;
                left: 12px;
                background: rgba(0,0,0,0.6);
                color: #fff;
                padding: 4px 12px;
                border-radius: 12px;
                font-size: 12px;
                opacity: 0;
                transition: opacity 0.5s;
                z-index: 5;
                pointer-events: none;
            }
            /* ===== 弹窗选择菜单 (清晰度/倍速) ===== */
            .hjm3u8-popover-container {
                position: relative;
            }
            .hjm3u8-popover-menu {
                display: none;
                position: absolute;
                bottom: 35px;
                left: 50%;
                transform: translateX(-50%);
                background: rgba(15, 15, 25, 0.95);
                border: 1px solid rgba(255, 255, 255, 0.15);
                border-radius: 8px;
                padding: 6px;
                flex-direction: column;
                gap: 4px;
                z-index: 100;
                box-shadow: 0 10px 30px rgba(0,0,0,0.5);
            }
            .hjm3u8-popover-menu.show {
                display: flex;
            }
            .hjm3u8-menu-item {
                padding: 6px 16px;
                background: transparent;
                border: none;
                color: #ccc;
                font-size: 12px;
                text-align: center;
                cursor: pointer;
                border-radius: 4px;
                white-space: nowrap;
                transition: all 0.2s;
                font-family: inherit;
            }
            .hjm3u8-menu-item:hover {
                background: rgba(255,255,255,0.1);
                color: #fff;
            }
            .hjm3u8-menu-item.active {
                background: rgba(99, 179, 237, 0.2);
                color: #63b3ed;
                font-weight: bold;
            }

            /* ===== 音量滑块 ===== */
            .hjm3u8-volume-container {
                display: flex;
                align-items: center;
                gap: 6px;
            }
            #hjm3u8-volume-slider {
                width: 60px;
                height: 3px;
                background: rgba(255, 255, 255, 0.3);
                outline: none;
                border: none;
                border-radius: 2px;
                cursor: pointer;
                accent-color: #63b3ed;
                -webkit-appearance: none;
            }
            #hjm3u8-volume-slider::-webkit-slider-runnable-track {
                height: 3px;
            }
            #hjm3u8-volume-slider::-webkit-slider-thumb {
                -webkit-appearance: none;
                width: 8px;
                height: 8px;
                border-radius: 50%;
                background: #fff;
                margin-top: -2.5px;
            }
            @media (max-width: 600px) {
                #hjm3u8-volume-slider {
                    display: none;
                }
            }

            /* ===== 实时网速/画质标签 ===== */
            #hjm3u8-stats-label {
                position: absolute;
                top: 12px;
                right: 56px;
                background: rgba(0,0,0,0.55);
                color: #9ae6b4;
                padding: 3px 10px;
                border-radius: 10px;
                font-size: 11px;
                z-index: 6;
                pointer-events: none;
                letter-spacing: 0.3px;
                max-width: 60%;
                white-space: nowrap;
                overflow: hidden;
                text-overflow: ellipsis;
            }

            /* ===== 缓冲加载动画 spinner ===== */
            #hjm3u8-spinner {
                position: absolute;
                top: 50%;
                left: 50%;
                width: 46px;
                height: 46px;
                margin: -23px 0 0 -23px;
                border: 4px solid rgba(255,255,255,0.2);
                border-top-color: #63b3ed;
                border-radius: 50%;
                animation: hjm3u8-spin 0.8s linear infinite;
                display: none;
                z-index: 6;
                pointer-events: none;
            }
            @keyframes hjm3u8-spin { to { transform: rotate(360deg); } }

            /* ===== 重新加载按钮高亮 ===== */
            #hjm3u8-reload-btn.attention {
                background: rgba(245, 101, 101, 0.5);
                border-color: #f56565;
                animation: hjm3u8-pulse 1s ease-in-out infinite;
            }
            @keyframes hjm3u8-pulse { 0%,100%{opacity:1;} 50%{opacity:0.5;} }

            /* ===== 播放按钮 ===== */
            .hjm3u8-play-btn {
                flex-shrink: 0;
                padding: 5px 8px;
                border-radius: 6px;
                background: rgba(183, 148, 244, 0.15);
                border: 1px solid rgba(183, 148, 244, 0.3);
                color: #b794f4;
                font-size: 11px;
                cursor: pointer;
                transition: all 0.2s;
                white-space: nowrap;
            }
            .hjm3u8-play-btn:hover {
                background: rgba(183, 148, 244, 0.3);
            }

            /* ===== Toast ===== */
            #hjm3u8-toast {
                position: fixed;
                top: 20px;
                left: 50%;
                transform: translateX(-50%) translateY(-100px);
                padding: 10px 24px;
                border-radius: 8px;
                background: rgba(30, 30, 40, 0.95);
                color: #fff;
                font-size: 13px;
                z-index: 2147483647;
                transition: transform 0.3s ease;
                pointer-events: none;
                backdrop-filter: blur(8px);
                -webkit-backdrop-filter: blur(8px);
                border: 1px solid rgba(255,255,255,0.1);
            }
            #hjm3u8-toast.show {
                transform: translateX(-50%) translateY(0);
            }
            @media (max-width: 768px) {
                #hjm3u8-player-controls {
                    padding-bottom: 24px;
                }
                #hjm3u8-volume-slider {
                    display: none;
                }
                .hjm3u8-cbtn {
                    padding: 6px 8px;
                    font-size: 13px;
                }
                #hjm3u8-time-display {
                    font-size: 11px;
                }
                #hjm3u8-player-container {
                    width: 95vw;
                    max-height: 80vh;
                }
            }
        `);
    }

    function createUI() {
        // 悬浮按钮
        floatBtn = document.createElement('div');
        floatBtn.id = 'hjm3u8-float-btn';
        floatBtn.innerHTML = '📋';
        document.body.appendChild(floatBtn);

        // 拖拽逻辑
        let isDragging = false;
        let hasDragged = false;
        let dragStartX = 0, dragStartY = 0;
        let btnStartX = 0, btnStartY = 0;

        const onDragStart = (e) => {
            isDragging = true;
            hasDragged = false;
            const clientX = e.touches ? e.touches[0].clientX : e.clientX;
            const clientY = e.touches ? e.touches[0].clientY : e.clientY;
            dragStartX = clientX;
            dragStartY = clientY;
            const rect = floatBtn.getBoundingClientRect();
            btnStartX = rect.left;
            btnStartY = rect.top;
            floatBtn.classList.add('dragging');
            e.preventDefault();
        };

        const onDragMove = (e) => {
            if (!isDragging) return;
            const clientX = e.touches ? e.touches[0].clientX : e.clientX;
            const clientY = e.touches ? e.touches[0].clientY : e.clientY;
            const dx = clientX - dragStartX;
            const dy = clientY - dragStartY;
            if (Math.abs(dx) > 3 || Math.abs(dy) > 3) hasDragged = true;
            if (!hasDragged) return;
            const newX = Math.max(0, Math.min(window.innerWidth - 52, btnStartX + dx));
            const newY = Math.max(0, Math.min(window.innerHeight - 52, btnStartY + dy));
            floatBtn.style.left = newX + 'px';
            floatBtn.style.top = newY + 'px';
            floatBtn.style.right = 'auto';
            floatBtn.style.bottom = 'auto';
            // 面板跟随
            if (panel) {
                panel.style.right = 'auto';
                panel.style.bottom = 'auto';
                panel.style.left = Math.min(newX, window.innerWidth - 460) + 'px';
                panel.style.top = Math.max(10, newY - panel.offsetHeight - 10) + 'px';
            }
        };

        const onDragEnd = () => {
            if (!isDragging) return;
            isDragging = false;
            floatBtn.classList.remove('dragging');
            if (!hasDragged) {
                togglePanel();
            }
        };

        floatBtn.addEventListener('mousedown', onDragStart);
        document.addEventListener('mousemove', onDragMove);
        document.addEventListener('mouseup', onDragEnd);
        floatBtn.addEventListener('touchstart', onDragStart, { passive: false });
        document.addEventListener('touchmove', onDragMove, { passive: false });
        document.addEventListener('touchend', onDragEnd);

        // 面板
        panel = document.createElement('div');
        panel.id = 'hjm3u8-panel';
        panel.innerHTML = `
            <div id="hjm3u8-panel-header">
                <h3>捕获到的m3u8地址 <span class="hj-count-badge">0</span></h3>
                <button id="hjm3u8-panel-close">&times;</button>
            </div>
            <div id="hjm3u8-panel-body">
                <div class="hjm3u8-empty">
                    ⏳ 暂无捕获，等待视频加载...<br>
                    <span class="hj-tip">请打开包含视频的帖子页面</span>
                </div>
            </div>
            <div id="hjm3u8-panel-footer">
                <button id="hjm3u8-copy-all">📋 复制全部</button>
                <button id="hjm3u8-play-first">▶ 播放</button>
                <button id="hjm3u8-dl-all">⬇ 下载</button>
            </div>
        `;
        document.body.appendChild(panel);

        panel.querySelector('#hjm3u8-panel-close').addEventListener('click', closePanel);
        panel.querySelector('#hjm3u8-copy-all').addEventListener('click', copyAll);
        panel.querySelector('#hjm3u8-dl-all').addEventListener('click', downloadAll);
        panel.querySelector('#hjm3u8-play-first').addEventListener('click', () => {
            if (capturedUrls.length === 0) {
                showToast('暂无可播放内容');
                return;
            }
            playM3u8(capturedUrls[0].url);
        });

        // 创建播放器覆盖层
        createPlayerOverlay();

        document.addEventListener('click', (e) => {
            if (panel.classList.contains('visible') &&
                !panel.contains(e.target) &&
                !floatBtn.contains(e.target)) {
                closePanel();
            }
        });

        // Toast
        toastEl = document.createElement('div');
        toastEl.id = 'hjm3u8-toast';
        document.body.appendChild(toastEl);
    }

    function togglePanel() {
        panel.classList.toggle('visible');
    }

    function closePanel() {
        panel.classList.remove('visible');
    }

    function showToast(msg) {
        toastEl.textContent = msg;
        toastEl.classList.add('show');
        setTimeout(() => toastEl.classList.remove('show'), 2000);
    }

    function copyToClipboard(text) {
        try {
            GM_setClipboard(text, 'text');
            showToast('✅ 复制成功');
        } catch (e) {
            try {
                navigator.clipboard.writeText(text).then(() => {
                    showToast('✅ 复制成功');
                }).catch(() => {
                    showToast('❌ 复制失败');
                });
            } catch (e2) {
                console.warn('[m3u8提取] 复制失败:', e2);
                showToast('❌ 复制失败');
            }
        }
    }

    function copyAll() {
        if (capturedUrls.length === 0) {
            showToast('暂无捕获内容');
            return;
        }
        const urls = capturedUrls.map(item => item.url);
        copyToClipboard(urls.join('\n'));
        showToast(`✅ 已复制 ${urls.length} 条地址`);
    }

    function downloadAll() {
        if (capturedUrls.length === 0) {
            showToast('暂无可下载内容');
            return;
        }
        for (const item of capturedUrls) {
            openDownloader(item.url);
        }
        showToast(`⬇ 已打开 ${capturedUrls.length} 个下载页`);
    }

    // ========== 内置 HLS 播放器 ==========
    let playerOverlay = null;
    let playerVideo = null;
    let hlsInstance = null;
    // ---- 播放器增强全局状态 ----
    let preloadHls = null;      // 预加载的独立 HLS 实例
    let preloadedUrl = null;    // 已预加载的 URL
    let currentPlayUrl = null;  // 当前播放的 URL
    let retryCount = 0;         // 错误重试次数
    let retryTimer = null;      // 重试定时器（指数退避）
    let posSaveTimer = null;    // 播放位置自动保存定时器
    let statsTimer = null;      // 网速/缓冲刷新定时器
    let manifestReadyDone = false; // 防止 manifest 就绪逻辑重复执行

    /** 持久化存储键名 */
    const PLAYER_KEYS = {
        speed: 'hjm3u8_last_speed',      // 上次使用的倍速
        quality: 'hjm3u8_quality_pref',  // 上次清晰度偏好（auto/高/中/低）
        bw: 'hjm3u8_bw_estimate'         // 上次带宽估计
    };

    /** GM_getValue 安全封装 */
    function pmGet(key, def) {
        try { return typeof GM_getValue !== 'undefined' ? GM_getValue(key, def) : def; }
        catch (e) { return def; }
    }
    /** GM_setValue 安全封装 */
    function pmSet(key, val) {
        try { if (typeof GM_setValue !== 'undefined') GM_setValue(key, val); }
        catch (e) { /* ignore */ }
    }
    /** 以视频 URL 生成稳定的位置存储键 */
    function posKey(url) {
        let h = 0;
        const s = url || '';
        for (let i = 0; i < s.length; i++) { h = (h << 5) - h + s.charCodeAt(i); h |= 0; }
        return 'hjpos_' + (h >>> 0);
    }
    /** 秒数格式化为 mm:ss */
    function formatTime(sec) {
        if (!isFinite(sec) || sec < 0) sec = 0;
        sec = Math.floor(sec);
        const m = Math.floor(sec / 60), s = sec % 60;
        return m + ':' + String(s).padStart(2, '0');
    }

    function createPlayerOverlay() {
        playerOverlay = document.createElement('div');
        playerOverlay.id = 'hjm3u8-player-overlay';
        playerOverlay.innerHTML = `
            <div id="hjm3u8-player-container">
                <video id="hjm3u8-player-video" playsinline webkit-playsinline></video>
                <button id="hjm3u8-player-close">&times;</button>
                <div id="hjm3u8-speed-display"></div>
                <div id="hjm3u8-player-info"></div>
                <div id="hjm3u8-stats-label"></div>
                <div id="hjm3u8-spinner"></div>

                <div id="hjm3u8-player-controls">
                    <!-- 进度条 -->
                    <div id="hjm3u8-progress-container">
                        <div id="hjm3u8-progress-bar">
                            <div id="hjm3u8-buffer-bar"></div>
                            <div id="hjm3u8-play-bar"></div>
                            <div id="hjm3u8-progress-handle"></div>
                        </div>
                    </div>

                    <!-- 按钮栏 -->
                    <div id="hjm3u8-controls-buttons">
                        <div class="hjm3u8-controls-left">
                            <button class="hjm3u8-cbtn" id="hjm3u8-play-btn">▶</button>
                            <button class="hjm3u8-cbtn" id="hjm3u8-prev-btn" title="上一个">⏮</button>
                            <button class="hjm3u8-cbtn" id="hjm3u8-next-btn" title="下一个">⏭</button>
                            <span id="hjm3u8-time-display">00:00 / 00:00</span>
                        </div>

                        <div class="hjm3u8-controls-right">
                            <!-- 清晰度/画质 -->
                            <div class="hjm3u8-popover-container">
                                <button class="hjm3u8-cbtn" id="hjm3u8-quality-btn" style="display:none;">自动</button>
                                <div class="hjm3u8-popover-menu" id="hjm3u8-quality-menu"></div>
                            </div>

                            <!-- 倍速 -->
                            <div class="hjm3u8-popover-container">
                                <button class="hjm3u8-cbtn" id="hjm3u8-speed-btn">倍速</button>
                                <div class="hjm3u8-popover-menu" id="hjm3u8-speed-menu">
                                    <button class="hjm3u8-menu-item" data-speed="0.5">0.5x</button>
                                    <button class="hjm3u8-menu-item active" data-speed="1">1.0x</button>
                                    <button class="hjm3u8-menu-item" data-speed="1.5">1.5x</button>
                                    <button class="hjm3u8-menu-item" data-speed="2">2.0x</button>
                                    <button class="hjm3u8-menu-item" data-speed="3">3.0x</button>
                                </div>
                            </div>

                            <!-- 音量 -->
                            <div class="hjm3u8-volume-container">
                                <button class="hjm3u8-cbtn" id="hjm3u8-volume-btn">🔊</button>
                                <input type="range" id="hjm3u8-volume-slider" min="0" max="1" step="0.05" value="1">
                            </div>

                            <button class="hjm3u8-cbtn" id="hjm3u8-reload-btn" title="重新加载">↻</button>
                            <button class="hjm3u8-cbtn" id="hjm3u8-pip-btn" title="画中画">📺</button>
                            <button class="hjm3u8-cbtn" id="hjm3u8-fullscreen-btn" title="全屏">⬜</button>
                        </div>
                    </div>
                </div>
            </div>
        `;
        document.body.appendChild(playerOverlay);

        playerVideo = playerOverlay.querySelector('#hjm3u8-player-video');

        // 关闭按钮
        playerOverlay.querySelector('#hjm3u8-player-close').addEventListener('click', closePlayer);

        // 点击遮罩关闭
        playerOverlay.addEventListener('click', (e) => {
            if (e.target === playerOverlay) closePlayer();
        });

        // 键盘快捷键（使用捕获阶段拦截，避免与页面方向键冲突/导致页面滚动）
        document.addEventListener('keydown', (e) => {
            if (!playerOverlay.classList.contains('visible')) return;
            const handledKeys = ['Escape', 'ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown', ' ', 'f', 'F'];
            if (handledKeys.includes(e.key)) {
                e.preventDefault();
                e.stopPropagation();
            }
            switch (e.key) {
                case 'Escape': closePlayer(); break;
                case 'ArrowLeft':  playerVideo.currentTime -= 5; showSpeedHint('⏪ -5s'); break;
                case 'ArrowRight': playerVideo.currentTime += 5; showSpeedHint('⏩ +5s'); break;
                case 'ArrowUp': {
                    const newVol = Math.min(1, playerVideo.volume + 0.1);
                    playerVideo.volume = newVol;
                    pmSet('hjm3u8_volume', newVol);
                    updateVolumeUI(newVol);
                    showSpeedHint('🔊 ' + Math.round(newVol * 100) + '%');
                    break;
                }
                case 'ArrowDown': {
                    const newVol = Math.max(0, playerVideo.volume - 0.1);
                    playerVideo.volume = newVol;
                    pmSet('hjm3u8_volume', newVol);
                    updateVolumeUI(newVol);
                    showSpeedHint('🔉 ' + Math.round(newVol * 100) + '%');
                    break;
                }
                case ' ': playerVideo.paused ? playerVideo.play().catch(()=>{}) : playerVideo.pause(); break;
                case 'f': case 'F': toggleFullscreen(); break;
            }
        }, true);

        // 控制栏自动隐藏/显示机制
        let controlsTimeout = null;
        const playerContainer = playerOverlay.querySelector('#hjm3u8-player-container');
        const showControls = () => {
            playerContainer.classList.add('show-controls');
            clearTimeout(controlsTimeout);
            if (!playerVideo.paused) {
                controlsTimeout = setTimeout(() => {
                    playerContainer.classList.remove('show-controls');
                    // 同时收起可能展开的弹窗菜单
                    playerOverlay.querySelector('#hjm3u8-quality-menu').classList.remove('show');
                    playerOverlay.querySelector('#hjm3u8-speed-menu').classList.remove('show');
                }, 3000);
            }
        };
        playerContainer.addEventListener('mousemove', showControls);
        playerContainer.addEventListener('touchstart', showControls, { passive: true });

        // 播放与暂停事件监听
        const playBtn = playerOverlay.querySelector('#hjm3u8-play-btn');
        playBtn.addEventListener('click', (e) => {
            e.stopPropagation();
            playerVideo.paused ? playerVideo.play().catch(()=>{}) : playerVideo.pause();
        });
        playerVideo.addEventListener('play', () => {
            playBtn.textContent = '⏸';
            showControls();
        });
        playerVideo.addEventListener('pause', () => {
            playBtn.textContent = '▶';
            showControls();
        });
        playerVideo.addEventListener('click', (e) => {
            e.stopPropagation();
            playerVideo.paused ? playerVideo.play().catch(()=>{}) : playerVideo.pause();
        });

        // 进度条拖拽与点击 Seek 逻辑
        const progressContainer = playerOverlay.querySelector('#hjm3u8-progress-container');
        const playBar = playerOverlay.querySelector('#hjm3u8-play-bar');
        const progressHandle = playerOverlay.querySelector('#hjm3u8-progress-handle');
        let isDraggingProgress = false;

        const updateProgressUI = (percent) => {
            playBar.style.width = percent + '%';
            progressHandle.style.left = percent + '%';
        };

        const seekToPosition = (e) => {
            const rect = progressContainer.getBoundingClientRect();
            const clientX = e.touches ? e.touches[0].clientX : e.clientX;
            const pos = Math.max(0, Math.min(1, (clientX - rect.left) / rect.width));
            updateProgressUI(pos * 100);
            if (playerVideo.duration) {
                playerVideo.currentTime = pos * playerVideo.duration;
            }
        };

        progressContainer.addEventListener('mousedown', (e) => {
            isDraggingProgress = true;
            seekToPosition(e);
        });
        document.addEventListener('mousemove', (e) => {
            if (isDraggingProgress) seekToPosition(e);
        });
        document.addEventListener('mouseup', () => {
            isDraggingProgress = false;
        });

        progressContainer.addEventListener('touchstart', (e) => {
            isDraggingProgress = true;
            seekToPosition(e);
        }, { passive: true });
        document.addEventListener('touchmove', (e) => {
            if (isDraggingProgress) seekToPosition(e);
        }, { passive: true });
        document.addEventListener('touchend', () => {
            isDraggingProgress = false;
        });

        // 播放进度与时间更新
        playerVideo.addEventListener('timeupdate', () => {
            if (!isDraggingProgress && playerVideo.duration) {
                const percent = (playerVideo.currentTime / playerVideo.duration) * 100;
                updateProgressUI(percent);
            }
            const timeDisplay = playerOverlay.querySelector('#hjm3u8-time-display');
            if (timeDisplay) {
                timeDisplay.textContent = `${formatTime(playerVideo.currentTime)} / ${formatTime(playerVideo.duration)}`;
            }
        });

        // 缓存进度更新
        playerVideo.addEventListener('progress', () => {
            const bufferBar = playerOverlay.querySelector('#hjm3u8-buffer-bar');
            if (bufferBar && playerVideo.duration) {
                const b = playerVideo.buffered;
                let bufEnd = 0;
                for (let i = 0; i < b.length; i++) {
                    if (b.start(i) <= playerVideo.currentTime && b.end(i) >= playerVideo.currentTime) {
                        bufEnd = b.end(i);
                        break;
                    }
                }
                bufferBar.style.width = (bufEnd / playerVideo.duration * 100) + '%';
            }
        });

        // 倍速弹出菜单事件绑定
        const speedBtn = playerOverlay.querySelector('#hjm3u8-speed-btn');
        const speedMenu = playerOverlay.querySelector('#hjm3u8-speed-menu');
        if (speedBtn && speedMenu) {
            speedBtn.addEventListener('click', (e) => {
                e.stopPropagation();
                playerOverlay.querySelector('#hjm3u8-quality-menu').classList.remove('show');
                speedMenu.classList.toggle('show');
            });

            speedMenu.querySelectorAll('.hjm3u8-menu-item').forEach(item => {
                item.addEventListener('click', (e) => {
                    e.stopPropagation();
                    const speed = parseFloat(item.dataset.speed);
                    playerVideo.playbackRate = speed;
                    speedMenu.querySelectorAll('.hjm3u8-menu-item').forEach(b => b.classList.remove('active'));
                    item.classList.add('active');
                    speedBtn.textContent = speed === 1 ? '倍速' : speed + 'x';
                    speedMenu.classList.remove('show');
                    showSpeedHint(speed + 'x');
                    pmSet(PLAYER_KEYS.speed, speed);
                });
            });
        }

        // 画质切换菜单弹出事件绑定 (具体的级别绑定在 setupQualitySelector 中完成)
        const qBtn = playerOverlay.querySelector('#hjm3u8-quality-btn');
        const qMenu = playerOverlay.querySelector('#hjm3u8-quality-menu');
        if (qBtn && qMenu) {
            qBtn.addEventListener('click', (e) => {
                e.stopPropagation();
                speedMenu.classList.remove('show');
                qMenu.classList.toggle('show');
            });
        }
        document.addEventListener('click', () => {
            qMenu?.classList.remove('show');
            speedMenu?.classList.remove('show');
        });

        // 音量调节逻辑
        const volumeBtn = playerOverlay.querySelector('#hjm3u8-volume-btn');
        const volumeSlider = playerOverlay.querySelector('#hjm3u8-volume-slider');
        let lastVolume = parseFloat(pmGet('hjm3u8_volume', 1)) || 1;
        playerVideo.volume = lastVolume;
        volumeSlider.value = lastVolume;

        const updateVolumeUI = (vol) => {
            volumeSlider.value = vol;
            if (vol === 0) {
                volumeBtn.textContent = '🔇';
            } else if (vol < 0.5) {
                volumeBtn.textContent = '🔉';
            } else {
                volumeBtn.textContent = '🔊';
            }
        };
        updateVolumeUI(lastVolume);

        volumeSlider.addEventListener('input', (e) => {
            e.stopPropagation();
            const vol = parseFloat(volumeSlider.value);
            playerVideo.volume = vol;
            lastVolume = vol;
            pmSet('hjm3u8_volume', vol);
            updateVolumeUI(vol);
        });
        volumeBtn.addEventListener('click', (e) => {
            e.stopPropagation();
            if (playerVideo.volume > 0) {
                playerVideo.volume = 0;
                updateVolumeUI(0);
            } else {
                playerVideo.volume = lastVolume || 1;
                updateVolumeUI(lastVolume || 1);
            }
        });

        // 画中画按钮
        playerOverlay.querySelector('#hjm3u8-pip-btn').addEventListener('click', async (e) => {
            e.stopPropagation();
            try {
                if (document.pictureInPictureElement) {
                    await document.exitPictureInPicture();
                } else if (playerVideo.requestPictureInPicture) {
                    await playerVideo.requestPictureInPicture();
                } else {
                    showToast('浏览器不支持画中画');
                }
            } catch (err) {
                showToast('画中画启动失败');
            }
        });

        // 全屏按钮
        playerOverlay.querySelector('#hjm3u8-fullscreen-btn').addEventListener('click', (e) => {
            e.stopPropagation();
            toggleFullscreen();
        });

        // 上一个/下一个
        playerOverlay.querySelector('#hjm3u8-prev-btn').addEventListener('click', (e) => { e.stopPropagation(); navigatePlaylist(-1); });
        playerOverlay.querySelector('#hjm3u8-next-btn').addEventListener('click', (e) => { e.stopPropagation(); navigatePlaylist(1); });

        // 阻止移动端视频区域的长按默认菜单（如保存视频）
        playerVideo.addEventListener('contextmenu', (e) => {
            e.preventDefault();
        });

        // 移动端手势控制：滑动调节进度/音量 + 长按加速
        let longPressTimer = null;
        let wasSpeed = 1;
        let isLongPressing = false;

        let touchStartX = 0;
        let touchStartY = 0;
        let videoStartTime = 0;
        let videoStartVol = 0;
        let hasMoved = false;
        let swipeDirection = null; // 'horizontal' | 'vertical' | null
        let gestureTargetTime = null;

        playerVideo.addEventListener('touchstart', (e) => {
            if (e.touches.length !== 1) return;
            const touch = e.touches[0];
            touchStartX = touch.clientX;
            touchStartY = touch.clientY;
            videoStartTime = playerVideo.currentTime;
            videoStartVol = playerVideo.volume;
            hasMoved = false;
            swipeDirection = null;
            gestureTargetTime = null;
            isLongPressing = false;

            // 长按定时器：如果 500ms 内没有移动，触发长按 2x 倍速
            longPressTimer = setTimeout(() => {
                if (hasMoved) return;
                isLongPressing = true;
                wasSpeed = playerVideo.playbackRate;
                playerVideo.playbackRate = 2;
                showSpeedHint('▶▶ 2x 长按加速中');
            }, 500);
        }, { passive: true });

        playerVideo.addEventListener('touchmove', (e) => {
            if (e.touches.length !== 1) return;
            const touch = e.touches[0];
            const dx = touch.clientX - touchStartX;
            const dy = touch.clientY - touchStartY;

            // 只要手指开始移动一定距离，立刻取消长按加速定时器
            if (!hasMoved && (Math.abs(dx) > 10 || Math.abs(dy) > 10)) {
                hasMoved = true;
                if (longPressTimer) {
                    clearTimeout(longPressTimer);
                    longPressTimer = null;
                }
            }

            if (isLongPressing) return; // 如果已经进入长按加速状态，不执行滑动调节逻辑

            // 识别滑动方向
            if (hasMoved && !swipeDirection) {
                if (Math.abs(dx) > Math.abs(dy)) {
                    swipeDirection = 'horizontal';
                } else {
                    swipeDirection = 'vertical';
                }
            }

            if (swipeDirection === 'horizontal') {
                // 水平滑动：调节进度（全屏宽度代表 180s 跨度）
                if (e.cancelable) e.preventDefault();
                const seekRatio = dx / playerVideo.clientWidth;
                const totalDuration = playerVideo.duration || 0;
                if (totalDuration > 0) {
                    gestureTargetTime = Math.max(0, Math.min(totalDuration, videoStartTime + seekRatio * 180));
                    // 实时在屏幕中央显示进度 HUD（不频繁更改 currentTime，防止拖拽卡顿）
                    showSpeedHint(`进度: ${formatTime(gestureTargetTime)} / ${formatTime(totalDuration)}`);
                    // 实时同步底部进度条 UI
                    const percent = (gestureTargetTime / totalDuration) * 100;
                    updateProgressUI(percent);
                }
            } else if (swipeDirection === 'vertical') {
                // 垂直滑动：调节音量 (仅在屏幕右半侧滑动时触发)
                if (e.cancelable) e.preventDefault();
                const rect = playerVideo.getBoundingClientRect();
                const isRightSide = touchStartX > (rect.left + rect.width / 2);
                if (isRightSide) {
                    const volDelta = -dy / playerVideo.clientHeight; // 向上滑 dy 为负，增加音量
                    const targetVol = Math.max(0, Math.min(1, videoStartVol + volDelta));
                    playerVideo.volume = targetVol;
                    updateVolumeUI(targetVol);
                    showSpeedHint(`音量: ${Math.round(targetVol * 100)}%`);
                }
            }
        }, { passive: false }); // 需要 preventDefault

        const releaseGesture = () => {
            if (longPressTimer) {
                clearTimeout(longPressTimer);
                longPressTimer = null;
            }

            if (isLongPressing) {
                // 恢复之前的速度
                playerVideo.playbackRate = wasSpeed;
                hideSpeedHint();
                isLongPressing = false;
            }

            if (swipeDirection === 'horizontal' && gestureTargetTime !== null) {
                // 结束滑动时，真正应用播放进度跳转
                playerVideo.currentTime = gestureTargetTime;
                hideSpeedHint();
                gestureTargetTime = null;
            } else if (swipeDirection === 'vertical') {
                hideSpeedHint();
            }

            swipeDirection = null;
            hasMoved = false;
        };

        playerVideo.addEventListener('touchend', releaseGesture, { passive: true });
        playerVideo.addEventListener('touchcancel', releaseGesture, { passive: true });

        // 双击全屏
        playerVideo.addEventListener('dblclick', (e) => {
            e.preventDefault();
            toggleFullscreen();
        });

        // 缓冲/加载状态 spinner 切换
        playerVideo.addEventListener('waiting', showSpinner);
        playerVideo.addEventListener('seeking', showSpinner);
        playerVideo.addEventListener('playing', hideSpinner);
        playerVideo.addEventListener('canplay', hideSpinner);
        playerVideo.addEventListener('seeked', hideSpinner);

        // 播放结束：清除该视频的位置记录
        playerVideo.addEventListener('ended', () => {
            try { if (currentPlayUrl) pmSet(posKey(currentPlayUrl), 0); } catch (err) { /* ignore */ }
        });

        // 手动重新加载按钮
        const reloadBtn = playerOverlay.querySelector('#hjm3u8-reload-btn');
        if (reloadBtn) {
            reloadBtn.addEventListener('click', (e) => {
                e.stopPropagation();
                if (currentPlayUrl) {
                    retryCount = 0;
                    hideReloadButton();
                    playM3u8(currentPlayUrl);
                }
            });
        }
    }

    function showSpeedHint(text) {
        const display = playerOverlay?.querySelector('#hjm3u8-speed-display');
        if (!display) return;
        display.textContent = text;
        display.classList.add('visible');
        clearTimeout(display._hideTimer);
        display._hideTimer = setTimeout(() => display.classList.remove('visible'), 800);
    }

    function hideSpeedHint() {
        const display = playerOverlay?.querySelector('#hjm3u8-speed-display');
        if (display) display.classList.remove('visible');
    }

    function toggleFullscreen() {
        const container = playerOverlay?.querySelector('#hjm3u8-player-container');
        if (!container) return;
        if (document.fullscreenElement) {
            document.exitFullscreen().catch(() => {});
        } else {
            (container.requestFullscreen || container.webkitRequestFullscreen || container.msRequestFullscreen)?.call(container);
        }
    }

    let currentPlayIndex = -1;

    /**
     * 从当前索引出发，沿指定方向查找下一个“非明确不可用”的条目索引。
     * playable === false 的条目会被跳过；找不到时返回 -1。
     * @param {number} direction 1=下一个，-1=上一个
     */
    function findAdjacentPlayable(direction) {
        for (let i = currentPlayIndex + direction; i >= 0 && i < capturedUrls.length; i += direction) {
            if (capturedUrls[i] && capturedUrls[i].playable !== false) return i;
        }
        return -1;
    }

    /** 更新播放器顶部位置指示（“播放 2/3”）与 上一个/下一个 按钮的可用状态 */
    function updatePlayerNav() {
        if (!playerOverlay) return;
        try {
            const total = capturedUrls.length;
            const infoEl = playerOverlay.querySelector('#hjm3u8-player-info');
            if (infoEl) {
                infoEl.textContent = total > 0 ? `播放 ${currentPlayIndex + 1}/${total}` : '';
                // 位置指示常驻显示（不再自动淡出）
                infoEl.style.opacity = total > 0 ? '1' : '0';
            }
            const prevBtn = playerOverlay.querySelector('#hjm3u8-prev-btn');
            const nextBtn = playerOverlay.querySelector('#hjm3u8-next-btn');
            // 到头/尾（或方向上无可播放条目）时禁用对应按钮
            if (prevBtn) prevBtn.disabled = (findAdjacentPlayable(-1) === -1);
            if (nextBtn) nextBtn.disabled = (findAdjacentPlayable(1) === -1);
        } catch (e) { /* ignore */ }
    }

    /**
     * 播放列表导航：向前/向后跳转到下一个可播放条目。
     * - 自动跳过已标记为不可用(playable===false)的条目；
     * - 到达边界时给出提示。
     * @param {number} direction 1=下一个，-1=上一个
     */
    function navigatePlaylist(direction) {
        try {
            if (capturedUrls.length === 0) {
                showToast('暂无可播放内容');
                return;
            }
            const target = findAdjacentPlayable(direction);
            if (target === -1) {
                showToast(direction > 0 ? '已是最后一个可播放视频' : '已是第一个可播放视频');
                return;
            }
            currentPlayIndex = target;
            playM3u8(capturedUrls[target].url);
        } catch (e) {
            console.warn('[m3u8提取] 播放列表导航失败:', e);
        }
    }

    /**
     * 当前地址播放失败时的优雅降级：
     * 1. 明确提示错误；2. 将当前条目标记为不可用（UI 变灰 + ⚠️）；
     * 3. 自动尝试列表中下一个可播放地址；4. 若无更多可用地址，高亮“重载”按钮。
     */
    function markCurrentUnplayableAndAdvance() {
        try {
            const item = capturedUrls[currentPlayIndex];
            if (item) { item.playable = false; updateUI(); }
            showToast('⚠️ 此地址无法播放，可能已过期');
            const next = findAdjacentPlayable(1);
            if (next !== -1) {
                currentPlayIndex = next;
                showToast('正在尝试下一个可播放地址…');
                playM3u8(capturedUrls[next].url);
            } else {
                updatePlayerNav();
                showReloadButton();
            }
        } catch (e) { /* ignore */ }
    }

    function playM3u8(url) {
        if (!playerOverlay || !playerVideo) return;
        // 记录当前播放索引
        const idx = capturedUrls.findIndex(item => item.url === url);
        if (idx !== -1) currentPlayIndex = idx;

        // 清理上一个视频的定时器与状态
        stopPositionSaver();
        stopStatsTimer();
        clearTimeout(retryTimer);
        retryCount = 0;
        manifestReadyDone = false;
        currentPlayUrl = url;

        // 先销毁旧实例（预加载实例除外，下面可能复用）
        if (hlsInstance) {
            try { hlsInstance.destroy(); } catch (e) { /* ignore */ }
            hlsInstance = null;
        }
        playerVideo.removeAttribute('src');

        // 恢复上次使用的倍速
        const savedSpeed = parseFloat(pmGet(PLAYER_KEYS.speed, 1)) || 1;
        playerVideo.playbackRate = savedSpeed;
        playerOverlay.querySelectorAll('[data-speed]').forEach(b => {
            b.classList.toggle('active', parseFloat(b.dataset.speed) === savedSpeed);
        });

        // 重置缓冲进度条
        const bufFill = playerOverlay.querySelector('#hjm3u8-buffer-fill');
        const playedFill = playerOverlay.querySelector('#hjm3u8-played-fill');
        if (bufFill) bufFill.style.width = '0';
        if (playedFill) playedFill.style.width = '0';

        // 更新播放位置指示与上/下一个按钮状态（常驻显示）
        updatePlayerNav();

        hideReloadButton();
        showSpinner();

        // 加载视频
        if (typeof Hls !== 'undefined' && Hls.isSupported()) {
            try {
                // 优先复用预加载实例，实现快速启动
                if (preloadHls && preloadedUrl === url) {
                    hlsInstance = preloadHls;
                    preloadHls = null;
                    preloadedUrl = null;
                    attachPlayerEvents(hlsInstance);
                    hlsInstance.attachMedia(playerVideo);
                    hlsInstance.startLoad();
                    // 预加载实例可能已解析完 manifest，手动触发后续逻辑
                    if (hlsInstance.levels && hlsInstance.levels.length) {
                        onManifestReady();
                    }
                } else {
                    hlsInstance = new Hls(buildHlsConfig());
                    attachPlayerEvents(hlsInstance);
                    hlsInstance.loadSource(url);
                    hlsInstance.attachMedia(playerVideo);
                }
            } catch (e) {
                console.warn('[m3u8提取] HLS 初始化失败:', e);
                showToast('播放器初始化失败');
                return;
            }
            startStatsTimer();
        } else if (playerVideo.canPlayType('application/vnd.apple.mpegurl')) {
            // 原生 HLS（如 Safari）
            playerVideo.src = url;
            playerVideo.addEventListener('loadedmetadata', () => {
                restorePosition();
                startPositionSaver();
                setupQualitySelector(); // 在 Safari 中元数据加载后显示分辨率标签
                playerVideo.play().catch(() => {});
            }, { once: true });
        } else {
            showToast('浏览器不支持 HLS 播放');
            return;
        }

        playerOverlay.classList.add('visible');
        closePanel();
        showToast('▶ 正在加载视频...');
    }

    /** 构建 HLS 配置：动态缓冲 + ABR 自适应 + 容错 */
    function buildHlsConfig() {
        const savedBw = parseInt(pmGet(PLAYER_KEYS.bw, 1500000)) || 1500000;
        return {
            // 动态缓冲初始值（会在 FRAG_LOADED 中根据带宽动态调整）
            maxBufferLength: 30,
            maxMaxBufferLength: 120,
            // 初始带宽估计，加快首帧画质决策
            abrEwmaDefaultEstimate: savedBw,
            // ABR 自适应平滑参数
            abrEwmaFastLive: 3.0,
            abrEwmaSlow: 9.0,
            startLevel: -1,           // 自动选择起始清晰度（开启 ABR）
            // 分片加载容错
            fragLoadingTimeOut: 20000,
            fragLoadingMaxRetry: 2,
            manifestLoadingMaxRetry: 3,
        };
    }
    /** 为 HLS 实例绑定核心事件（manifest / 分片 / 错误） */
    function attachPlayerEvents(hls) {
        try {
            hls.on(Hls.Events.MANIFEST_PARSED, () => onManifestReady());
            hls.on(Hls.Events.FRAG_LOADED, onFragLoaded);
            hls.on(Hls.Events.ERROR, (event, data) => handleHlsError(data));
        } catch (e) { /* ignore */ }
    }

    /** manifest 就绪后的统一处理（并防重复执行） */
    function onManifestReady() {
        if (manifestReadyDone) return;
        manifestReadyDone = true;
        try {
            // manifest 解析成功 → 确认当前地址可播放（清除可能的“不可用”标记）
            if (currentPlayUrl) setUrlPlayable(currentPlayUrl, true);
            setupQualitySelector();
            applyQualityPreference();
            // duration 就绪后恢复播放位置
            if (playerVideo.readyState >= 1 && playerVideo.duration) {
                restorePosition();
                startPositionSaver();
                setupQualitySelector();
            } else {
                playerVideo.addEventListener('loadedmetadata', () => {
                    restorePosition();
                    startPositionSaver();
                    setupQualitySelector();
                }, { once: true });
            }
            playerVideo.play().catch(() => {});
        } catch (e) { /* ignore */ }
    }

    /** 分片加载成功回调：重置重试计数 + 动态缓冲策略 */
    function onFragLoaded() {
        try {
            retryCount = 0; // 成功加载分片，重置重试计数
            hideSpinner();
            if (!hlsInstance) return;
            const bw = hlsInstance.bandwidthEstimate || 0;
            if (bw > 0) pmSet(PLAYER_KEYS.bw, Math.round(bw));
            // 动态缓冲：网络越好缓冲越大（最大120s），网络越差缓冲越小（最小10s）
            let target;
            if (bw > 5000000) target = 120;
            else if (bw > 2000000) target = 60;
            else if (bw > 800000) target = 30;
            else target = 10;
            hlsInstance.config.maxMaxBufferLength = target;
            hlsInstance.config.maxBufferLength = Math.min(30, target);
        } catch (e) { /* ignore */ }
    }

    /** 统一错误处理：指数退避重试 + 降级画质 + 媒体恢复 + 跳过超时分片 */
    function handleHlsError(data) {
        try {
            if (!data) return;
            if (!data.fatal) {
                // 非致命：分片加载超时/错误 → 跳过该段继续播放
                if (data.details === Hls.ErrorDetails.FRAG_LOAD_TIMEOUT ||
                    data.details === Hls.ErrorDetails.FRAG_LOAD_ERROR) {
                    try { if (hlsInstance) hlsInstance.startLoad(); } catch (e) { /* ignore */ }
                }
                return;
            }
            console.warn('[m3u8提取] HLS fatal error:', data.type, data.details);
            switch (data.type) {
                case Hls.ErrorTypes.NETWORK_ERROR:
                    downgradeQuality();  // 网络错误自动降一档清晰度
                    scheduleRetry();     // 指数退避重试
                    break;
                case Hls.ErrorTypes.MEDIA_ERROR:
                    showToast('媒体错误，尝试恢复...');
                    try { hlsInstance.recoverMediaError(); }
                    catch (e) { scheduleRetry(); }
                    break;
                default:
                    // 其余致命错误（如 manifest 加载失败/地址过期）：优雅降级至下一可播放地址
                    markCurrentUnplayableAndAdvance();
                    break;
            }
        } catch (e) { /* ignore */ }
    }

    /** 指数退避重试（1s, 2s, 4s, 8s, 最大16s，最多5次） */
    function scheduleRetry() {
        if (retryCount >= 5) {
            // 多次重试仍失败 → 标记不可用并自动尝试下一个可播放地址
            markCurrentUnplayableAndAdvance();
            return;
        }
        const delay = Math.min(16000, 1000 * Math.pow(2, retryCount));
        retryCount++;
        showToast(`网络错误，${delay / 1000}s 后第 ${retryCount} 次重试...`);
        clearTimeout(retryTimer);
        retryTimer = setTimeout(() => {
            try { if (hlsInstance) hlsInstance.startLoad(); } catch (e) { /* ignore */ }
        }, delay);
    }

    /** 降低一档清晰度 */
    function downgradeQuality() {
        try {
            if (!hlsInstance || !hlsInstance.levels) return;
            const cur = hlsInstance.currentLevel;
            const lvl = (cur === -1) ? hlsInstance.loadLevel : cur;
            if (lvl > 0) {
                hlsInstance.currentLevel = lvl - 1;
                showSpeedHint('↓ 已降低清晰度');
            }
        } catch (e) { /* ignore */ }
    }

    /** 恢复上次播放位置 */
    function restorePosition() {
        try {
            const pos = parseFloat(pmGet(posKey(currentPlayUrl), 0)) || 0;
            const dur = playerVideo.duration || 0;
            if (pos > 5 && (!dur || pos < dur - 5)) {
                playerVideo.currentTime = pos;
                showToast('已恢复到 ' + formatTime(pos));
            }
        } catch (e) { /* ignore */ }
    }

    /** 每10秒自动保存一次播放位置 */
    function startPositionSaver() {
        stopPositionSaver();
        posSaveTimer = setInterval(() => {
            try {
                if (playerVideo && !playerVideo.paused && playerVideo.currentTime > 0) {
                    pmSet(posKey(currentPlayUrl), Math.floor(playerVideo.currentTime));
                }
            } catch (e) { /* ignore */ }
        }, 10000);
    }
    function stopPositionSaver() {
        if (posSaveTimer) { clearInterval(posSaveTimer); posSaveTimer = null; }
    }

    /** 启动/停止 网速与缓冲刷新定时器 */
    function startStatsTimer() {
        stopStatsTimer();
        statsTimer = setInterval(() => {
            updateStatsLabel();
        }, 1000);
    }
    function stopStatsTimer() {
        if (statsTimer) { clearInterval(statsTimer); statsTimer = null; }
    }

    /** 实时更新网速/画质标签 */
    function updateStatsLabel() {
        try {
            const el = playerOverlay?.querySelector('#hjm3u8-stats-label');
            if (!el || !hlsInstance) return;
            const bw = hlsInstance.bandwidthEstimate || 0;
            const mbps = (bw / 1e6).toFixed(1);
            let q = '自动';
            const lvl = hlsInstance.currentLevel;
            const levels = hlsInstance.levels || [];
            if (lvl >= 0 && levels[lvl]) {
                q = levels[lvl].height ? levels[lvl].height + 'p' : (levels[lvl].name || '');
            } else {
                const al = levels[hlsInstance.loadLevel];
                q = '自动' + (al && al.height ? '(' + al.height + 'p)' : '');
            }
            el.textContent = `${q} · ${mbps} Mbps`;
        } catch (e) { /* ignore */ }
    }

    /** 更新缓冲进度条（缓冲范围 + 已播进度） */
    function updateBufferBar() {
        try {
            const wrap = playerOverlay?.querySelector('#hjm3u8-progress-wrap');
            if (!wrap) return;
            const bufFill = wrap.querySelector('#hjm3u8-buffer-fill');
            const playedFill = wrap.querySelector('#hjm3u8-played-fill');
            const dur = playerVideo.duration;
            if (!dur || !isFinite(dur)) return;
            let bufEnd = 0;
            const b = playerVideo.buffered;
            for (let i = 0; i < b.length; i++) {
                if (b.start(i) <= playerVideo.currentTime && b.end(i) >= playerVideo.currentTime) {
                    bufEnd = b.end(i);
                    break;
                }
            }
            if (bufFill) bufFill.style.width = Math.min(100, bufEnd / dur * 100) + '%';
            if (playedFill) playedFill.style.width = Math.min(100, playerVideo.currentTime / dur * 100) + '%';
        } catch (e) { /* ignore */ }
    }

    /** 显示/隐藏 加载动画 spinner */
    function showSpinner() {
        const sp = playerOverlay?.querySelector('#hjm3u8-spinner');
        if (sp) sp.style.display = 'block';
    }
    function hideSpinner() {
        const sp = playerOverlay?.querySelector('#hjm3u8-spinner');
        if (sp) sp.style.display = 'none';
    }

    /** 高亮/取消高亮 重新加载按钮 */
    function showReloadButton() {
        const btn = playerOverlay?.querySelector('#hjm3u8-reload-btn');
        if (btn) btn.classList.add('attention');
    }
    function hideReloadButton() {
        const btn = playerOverlay?.querySelector('#hjm3u8-reload-btn');
        if (btn) btn.classList.remove('attention');
    }

    /** 预加载下一个视频的 manifest（仅加载 manifest，不加载分片） */
    function preloadNext() {
        try {
            if (capturedUrls.length < 2) return;
            const nextIdx = currentPlayIndex + 1;
            if (nextIdx >= capturedUrls.length) return;
            const nextUrl = capturedUrls[nextIdx].url;
            if (!nextUrl || preloadedUrl === nextUrl) return;
            if (typeof Hls === 'undefined' || !Hls.isSupported()) return;
            destroyPreload();
            // autoStartLoad:false → 仅加载并解析 manifest，不加载分片
            preloadHls = new Hls(Object.assign(buildHlsConfig(), { autoStartLoad: false }));
            preloadedUrl = nextUrl;
            preloadHls.on(Hls.Events.ERROR, (event, data) => {
                if (data && data.fatal) destroyPreload();
            });
            preloadHls.loadSource(nextUrl);
            console.log('[m3u8提取] 预加载下一个视频 manifest:', nextUrl);
        } catch (e) { destroyPreload(); }
    }
    /** 销毁预加载实例 */
    function destroyPreload() {
        try { if (preloadHls) preloadHls.destroy(); } catch (e) { /* ignore */ }
        preloadHls = null;
        preloadedUrl = null;
    }

    /** 清晰度级别映射为偏好分类 */
    function levelToPref(idx, n) {
        if (idx === -1) return 'auto';
        if (idx >= n - 1) return '高';
        if (idx <= 0) return '低';
        return '中';
    }
    /** 偏好分类映射为当前可用的级别索引 */
    function prefToLevel(pref, n) {
        if (pref === '高') return n - 1;
        if (pref === '低') return 0;
        if (pref === '中') return Math.floor((n - 1) / 2);
        return -1; // auto
    }
    function applyQualityPreference() {
        try {
            if (!hlsInstance || !hlsInstance.levels || hlsInstance.levels.length < 2) return;
            const pref = pmGet(PLAYER_KEYS.quality, 'auto');
            const n = hlsInstance.levels.length;
            const target = prefToLevel(pref, n);
            hlsInstance.currentLevel = target;
            // 同步 UI 选中状态
            const qBtn = playerOverlay.querySelector('#hjm3u8-quality-btn');
            const qMenu = playerOverlay.querySelector('#hjm3u8-quality-menu');
            if (qMenu) {
                qMenu.querySelectorAll('.hjm3u8-menu-item').forEach(b => {
                    const active = parseInt(b.dataset.level) === target;
                    b.classList.toggle('active', active);
                    if (active && qBtn) qBtn.textContent = b.textContent;
                });
            }
        } catch (e) { /* ignore */ }
    }

    function closePlayer() {
        if (!playerOverlay) return;
        playerOverlay.classList.remove('visible');

        // 关闭前保存当前播放位置
        try {
            if (currentPlayUrl && playerVideo && playerVideo.currentTime > 5) {
                pmSet(posKey(currentPlayUrl), Math.floor(playerVideo.currentTime));
            }
        } catch (e) { /* ignore */ }

        // 清理定时器
        stopPositionSaver();
        stopStatsTimer();
        clearTimeout(retryTimer);

        const qBtn = playerOverlay.querySelector('#hjm3u8-quality-btn');
        const qMenu = playerOverlay.querySelector('#hjm3u8-quality-menu');
        const speedBtn = playerOverlay.querySelector('#hjm3u8-speed-btn');
        const speedMenu = playerOverlay.querySelector('#hjm3u8-speed-menu');
        if (qBtn) {
            qBtn.style.display = 'none';
            qBtn.textContent = '自动';
        }
        if (qMenu) {
            qMenu.classList.remove('show');
            qMenu.innerHTML = '';
        }
        if (speedBtn) {
            speedBtn.textContent = '倍速';
        }
        if (speedMenu) {
            speedMenu.classList.remove('show');
        }
        // 彻底清理 HLS 实例与预加载实例
        if (hlsInstance) {
            try { hlsInstance.destroy(); } catch (e) { /* ignore */ }
            hlsInstance = null;
        }
        destroyPreload();
        try {
            playerVideo.pause();
            playerVideo.removeAttribute('src');
            playerVideo.load();
        } catch (e) { /* ignore */ }
        hideSpinner();
        if (document.pictureInPictureElement) {
            document.exitPictureInPicture().catch(() => {});
        }
        if (document.fullscreenElement) {
            document.exitFullscreen().catch(() => {});
        }
    }

    function setupQualitySelector() {
        const qBtn = playerOverlay.querySelector('#hjm3u8-quality-btn');
        const qMenu = playerOverlay.querySelector('#hjm3u8-quality-menu');
        if (!qBtn || !qMenu) return;

        // 默认直接显示画质选项按钮，避免用户产生“没有设置清晰度”的困惑
        qBtn.style.display = 'inline-block';

        const levels = hlsInstance ? hlsInstance.levels : null;
        if (levels && levels.length > 1) {
            let menuHtml = '<button class="hjm3u8-menu-item active" data-level="-1">自动</button>';
            levels.forEach((level, index) => {
                const name = level.name || (level.height ? level.height + 'P' : '画质 ' + index);
                menuHtml += `<button class="hjm3u8-menu-item" data-level="${index}">${name}</button>`;
            });
            qMenu.innerHTML = menuHtml;

            qMenu.querySelectorAll('.hjm3u8-menu-item').forEach(item => {
                item.addEventListener('click', (e) => {
                    e.stopPropagation();
                    const levelIdx = parseInt(item.dataset.level);
                    hlsInstance.currentLevel = levelIdx;
                    qMenu.querySelectorAll('.hjm3u8-menu-item').forEach(b => b.classList.remove('active'));
                    item.classList.add('active');
                    qBtn.textContent = item.textContent;
                    qMenu.classList.remove('show');
                    showSpeedHint('已切换画质: ' + item.textContent);
                    // 记忆清晰度偏好（auto/高/中/低）
                    pmSet(PLAYER_KEYS.quality, levelToPref(levelIdx, levels.length));
                });
            });
        } else {
            // 单画质视频流，或者处于 native Safari 播放路径下：
            // 尝试读取视频的实际分辨率高度（如 1080P, 720P）
            let qualityLabel = '自动';
            if (playerVideo && playerVideo.videoHeight) {
                qualityLabel = playerVideo.videoHeight + 'P';
            }
            qBtn.textContent = qualityLabel;
            qMenu.innerHTML = `<button class="hjm3u8-menu-item active" data-level="-1">${qualityLabel}</button>`;
            qMenu.querySelectorAll('.hjm3u8-menu-item').forEach(item => {
                item.addEventListener('click', (e) => {
                    e.stopPropagation();
                    qMenu.classList.remove('show');
                });
            });
        }
    }

    function openDownloader(url) {
        window.open(
            `https://m3u8player.app/zh-CN/m3u8-downloader/?video_url=${encodeURIComponent(url)}`,
            '_blank'
        );
    }

    function getSourceBadge(source) {
        const map = {
            'XHR Hook': { cls: 'xhr', label: 'XHR' },
            'Fetch Hook': { cls: 'fetch', label: 'Fetch' },
            'TS反推': { cls: 'ts', label: 'TS反推' },
            'DOM监控': { cls: 'dom', label: 'DOM' },
            'Performance API': { cls: 'perf', label: 'Perf' },
            'API解密': { cls: 'api', label: 'API解密' },
            '播放器劫持': { cls: 'player', label: '播放器' },
            'MSE监控': { cls: 'mse', label: 'MSE' },
            'Blob捕获': { cls: 'blob', label: 'Blob' },
            '存储扫描': { cls: 'storage', label: '存储' },
            'WebSocket': { cls: 'ws', label: 'WS' }
        };
        return map[source] || { cls: 'xhr', label: source };
    }

    function updateUI() {
        if (!floatBtn) return;

        const count = capturedUrls.length;
        if (count > 0) {
            floatBtn.classList.add('has-capture');
            floatBtn.innerHTML = `<span style="font-size:16px;font-weight:bold;">${count}</span>`;
        } else {
            floatBtn.classList.remove('has-capture');
            floatBtn.innerHTML = '📋';
        }

        if (!panel) return;
        const body = panel.querySelector('#hjm3u8-panel-body');
        const countBadge = panel.querySelector('.hj-count-badge');
        if (countBadge) countBadge.textContent = count;

        if (count === 0) {
            body.innerHTML = `
                <div class="hjm3u8-empty">
                    ⏳ 暂无捕获，等待视频加载...<br>
                    <span class="hj-tip">请打开包含视频的帖子页面</span>
                </div>`;
            return;
        }

        let html = '';
        for (const item of capturedUrls) {
            const escapedUrl = item.url.replace(/"/g, '&quot;');
            // 生成多个来源 badge
            let badgesHtml = '';
            for (const src of item.sources) {
                const badge = getSourceBadge(src);
                badgesHtml += `<span class="hjm3u8-badge ${badge.cls}">${badge.label}</span>`;
            }
            // 可播放状态：true=✓可播放 / false=⚠️不可用(变灰) / null=验证中
            let itemCls = 'hjm3u8-item';
            let statusIcon = '';
            if (item.playable === true) {
                statusIcon = '<span class="hjm3u8-status ok" title="可播放">✓</span>';
            } else if (item.playable === false) {
                itemCls += ' unplayable';
                statusIcon = '<span class="hjm3u8-status warn" title="此地址可能已过期/无效">⚠️</span>';
            } else {
                statusIcon = '<span class="hjm3u8-status pending" title="验证中…">…</span>';
            }
            // 不可用条目额外提供“重试验证”按钮
            const retryBtn = item.playable === false
                ? `<button class="hjm3u8-retry-btn" data-url="${escapedUrl}" title="重新验证">↻</button>`
                : '';
            html += `
                <div class="${itemCls}">
                    <div class="hjm3u8-badges">${statusIcon}${badgesHtml}</div>
                    <span class="hjm3u8-url" title="${escapedUrl}">${item.url}</span>
                    <div class="hjm3u8-actions">
                        <button class="hjm3u8-play-btn" data-url="${escapedUrl}">▶</button>
                        ${retryBtn}
                        <button class="hjm3u8-copy-btn" data-url="${escapedUrl}">复制</button>
                        <button class="hjm3u8-dl-btn" data-url="${escapedUrl}">下载</button>
                    </div>
                </div>
            `;
        }
        body.innerHTML = html;

        body.querySelectorAll('.hjm3u8-copy-btn').forEach(btn => {
            btn.addEventListener('click', (e) => {
                e.stopPropagation();
                copyToClipboard(btn.dataset.url);
            });
        });
        body.querySelectorAll('.hjm3u8-play-btn').forEach(btn => {
            btn.addEventListener('click', (e) => {
                e.stopPropagation();
                playM3u8(btn.dataset.url);
            });
        });
        body.querySelectorAll('.hjm3u8-dl-btn').forEach(btn => {
            btn.addEventListener('click', (e) => {
                e.stopPropagation();
                openDownloader(btn.dataset.url);
            });
        });
        // 重试验证（仅不可用条目）：重置为“验证中”并重新拉取校验
        body.querySelectorAll('.hjm3u8-retry-btn').forEach(btn => {
            btn.addEventListener('click', (e) => {
                e.stopPropagation();
                const url = btn.dataset.url;
                setUrlPlayable(url, null);
                verifyCapturedUrl(url);
                showToast('↻ 正在重新验证…');
            });
        });
        // 列表/状态变化后，若播放器已打开则同步导航按钮与位置指示
        if (playerOverlay && playerOverlay.classList.contains('visible')) {
            updatePlayerNav();
        }
    }

    // ========== 初始化 ==========

    // 反调试绕过（最早安装）
    installAntiDebugBypass();

    // 广告拦截（尽早）
    installAdBlocker();

    // 通道1: XHR Hook（document-start 时立即安装）
    installXHRHook();

    // 通道2: Fetch Hook
    installFetchHook();

    // SPA 路由监控
    installRouteWatcher();

    // 通道3: DOM Observer
    installDOMObserver();

    // 通道4: Performance Observer
    installPerformanceObserver();

    // 通道6: MSE Hook（尽早安装）
    installMSEHook();

    // 通道7: Blob Hook（尽早安装）
    installBlobHook();

    // 通道9: WebSocket Hook（尽早安装）
    installWebSocketHook();

    // 通道8: Storage Monitor
    installStorageMonitor();

    // 通道5: 播放器劫持（DOM Ready 后）
    installPlayerHijack();

    // 自动展开帖子内容
    installAutoExpand();

    // UI 初始化
    const initUI = () => {
        if (document.body) {
            injectStyles();
            createUI();
        } else {
            document.addEventListener('DOMContentLoaded', () => {
                injectStyles();
                createUI();
            });
        }
    };

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', initUI);
    } else {
        initUI();
    }

    console.log('[m3u8提取] 全通道版 v5.9 已加载');
})();
