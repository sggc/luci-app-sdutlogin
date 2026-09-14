-- aes.lua — 纯 Lua 5.1 实现 AES-128-ECB(PKCS7) + base64，零依赖
-- 供 sdut-login.sh 在无 openssl 的 OpenWrt 上完成 eportal 参数加密
--
-- 用法:
--   lua aes.lua encrypt "<字符串>"   输出 base64 密文（等价前端 util.aes_en）
--   lua aes.lua b64 "<字符串>"       输出原始字节的 base64
--   lua aes.lua selftest             运行已知答案自检，全部通过输出 PASS 并返回 0
--
-- 密钥与算法来自校园网 eportal 前端 a41.js/a42.js:
--   AES-128-ECB / PKCS7, key = "5c1d5ad4dea0e8dd"

local sbox = {
    0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
    0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
    0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
    0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
    0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
    0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
    0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
    0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
    0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
    0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
    0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
    0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
    0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
    0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
    0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
    0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16,
}
local rcon = {0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80,0x1b,0x36}
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

-- Lua 5.1 没有位运算，用算术法实现 8 位异或
local function bxor(a, b)
    local r, p = 0, 1
    for _ = 1, 8 do
        local ba, bb = a % 2, b % 2
        if ba ~= bb then r = r + p end
        a = (a - ba) / 2
        b = (b - bb) / 2
        p = p * 2
    end
    return r
end

-- 预计算 xtime 表: XT[a] = GF(2^8) 上 a*2（模 x^8+x^4+x^3+x+1）
local XT = {}
for a = 0, 255 do
    local v = a * 2
    if v > 255 then v = v - 256 end
    if a > 127 then v = bxor(v, 0x1b) end
    XT[a] = v
end

local function key_expansion(key)  -- key: 16 字节字符串，返回 44 个字（各 4 字节）
    local kb = {string.byte(key, 1, 16)}
    local W = {}
    for i = 0, 3 do
        W[i] = {kb[i*4+1], kb[i*4+2], kb[i*4+3], kb[i*4+4]}
    end
    for i = 4, 43 do
        local t1, t2, t3, t4 = W[i-1][1], W[i-1][2], W[i-1][3], W[i-1][4]
        if i % 4 == 0 then
            t1, t2, t3, t4 = sbox[t2+1], sbox[t3+1], sbox[t4+1], sbox[t1+1]
            t1 = bxor(t1, rcon[i/4])
        end
        W[i] = {
            bxor(W[i-4][1], t1), bxor(W[i-4][2], t2),
            bxor(W[i-4][3], t3), bxor(W[i-4][4], t4),
        }
    end
    return W
end

local function encrypt_block(block, W)  -- block: 恰好 16 字节的字符串
    local s = {string.byte(block, 1, 16)}
    local function addrk(rnd)
        for c = 0, 3 do
            local w = W[rnd*4 + c]
            for r = 0, 3 do
                local idx = r + 1 + c*4
                s[idx] = bxor(s[idx], w[r+1])
            end
        end
    end
    addrk(0)
    for rnd = 1, 9 do
        for i = 1, 16 do s[i] = sbox[s[i]+1] end            -- SubBytes
        for r = 1, 3 do                                      -- ShiftRows
            local i1, i2, i3, i4 = r+1, r+5, r+9, r+13
            local t1, t2, t3, t4 = s[i1], s[i2], s[i3], s[i4]
            if     r == 1 then s[i1], s[i2], s[i3], s[i4] = t2, t3, t4, t1
            elseif r == 2 then s[i1], s[i2], s[i3], s[i4] = t3, t4, t1, t2
            else            s[i1], s[i2], s[i3], s[i4] = t4, t1, t2, t3 end
        end
        for c = 0, 3 do                                      -- MixColumns
            local i = c*4
            local a1, a2, a3, a4 = s[i+1], s[i+2], s[i+3], s[i+4]
            local x1, x2, x3, x4 = XT[a1], XT[a2], XT[a3], XT[a4]
            s[i+1] = bxor(bxor(bxor(x1, bxor(x2, a2)), a3), a4)
            s[i+2] = bxor(bxor(bxor(a1, x2), bxor(x3, a3)), a4)
            s[i+3] = bxor(bxor(bxor(a1, a2), x3), bxor(x4, a4))
            s[i+4] = bxor(bxor(bxor(x1, a1), bxor(a2, a3)), x4)
        end
        addrk(rnd)
    end
    for i = 1, 16 do s[i] = sbox[s[i]+1] end                 -- 末轮: 无 MixColumns
    for r = 1, 3 do
        local i1, i2, i3, i4 = r+1, r+5, r+9, r+13
        local t1, t2, t3, t4 = s[i1], s[i2], s[i3], s[i4]
        if     r == 1 then s[i1], s[i2], s[i3], s[i4] = t2, t3, t4, t1
        elseif r == 2 then s[i1], s[i2], s[i3], s[i4] = t3, t4, t1, t2
        else            s[i1], s[i2], s[i3], s[i4] = t4, t1, t2, t3 end
    end
    addrk(10)
    local unpack = unpack or table.unpack
    return string.char(unpack(s))
end

local function pkcs7(data)
    local pad = 16 - #data % 16
    return data .. string.rep(string.char(pad), pad)
end

-- 输入任意长度字符串，返回 ECB 模式密文（含 PKCS7 填充）
local function aes_ecb_encrypt(data, key)
    data = pkcs7(data)
    local W = key_expansion(key)
    local out = {}
    for i = 1, #data, 16 do
        out[#out + 1] = encrypt_block(data:sub(i, i + 15), W)
    end
    return table.concat(out)
end

local function b64encode(data)
    local out, len = {}, #data
    for i = 1, len, 3 do
        local a, b, c = data:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local q = {}
        for j = 3, 0, -1 do
            local idx = math.floor(n / 64 ^ j) % 64 + 1
            q[4 - j] = B64:sub(idx, idx)
        end
        if not c then q[4] = "="; if not b then q[3] = "=" end end
        out[#out + 1] = table.concat(q)
    end
    return table.concat(out)
end

local function hex(s)
    return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

local KEY = "5c1d5ad4dea0e8dd"
local mode = arg and arg[1] or ""

if mode == "selftest" then
    -- 1) FIPS-197 标准向量
    local fk = string.char(0x00,0x01,0x02,0x03,0x04,0x05,0x06,0x07,
                           0x08,0x09,0x0a,0x0b,0x0c,0x0d,0x0e,0x0f)
    local fp = string.char(0x00,0x11,0x22,0x33,0x44,0x55,0x66,0x77,
                           0x88,0x99,0xaa,0xbb,0xcc,0xdd,0xee,0xff)
    local ok = true
    local got = hex(encrypt_block(fp, key_expansion(fk)))
    local want = "69c4e0d86a7b0430d8cdb78070b4c55a"
    print("FIPS-197 : " .. got .. " " .. (got == want and "PASS" or "FAIL(exp " .. want .. ")"))
    ok = ok and (got == want)
    -- 2) 实抓包已知密文: encrypt("0") -> 775S4lvuSJoOMQjKw92ZKA==
    local got2 = b64encode(aes_ecb_encrypt("0", KEY))
    local want2 = "775S4lvuSJoOMQjKw92ZKA=="
    print("capture  : " .. got2 .. " " .. (got2 == want2 and "PASS" or "FAIL(exp " .. want2 .. ")"))
    ok = ok and (got2 == want2)
    -- 3) base64 边界
    local b_ok = b64encode("Man") == "TWFu" and b64encode("Ma") == "TWE=" and b64encode("M") == "TQ=="
    print("base64   : " .. (b_ok and "PASS" or "FAIL"))
    ok = ok and b_ok
    os.exit(ok and 0 or 1)
elseif mode == "encrypt" and arg[2] then
    io.write(b64encode(aes_ecb_encrypt(arg[2], KEY)), "\n")
elseif mode == "b64" and arg[2] then
    io.write(b64encode(arg[2]), "\n")
else
    io.stderr:write("usage: lua aes.lua {encrypt <s>|b64 <s>|selftest}\n")
    os.exit(1)
end
