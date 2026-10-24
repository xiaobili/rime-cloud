-- Minimal Hanyu Pinyin syllable recognizer used to avoid blocking on
-- incomplete prefixes.  It is deliberately dependency-free: a prefix such as
-- "walik" is recognised as incomplete (it can become "waliku"/"walikun"),
-- while "walikun" ends on a terminal syllable and is a good point to wait for
-- a cloud answer.  Abbreviations such as "nsdd" cannot be segmented and cannot
-- be extended into pinyin, so they are treated as a completion candidate.

local M = {}

local SYLLABLES = [[
a ai an ang ao
ba bai ban bang bao bei ben beng bi bian biao bie bin bing bo bu
ca cai can cang cao ce cen ceng cha chai chan chang chao che chen cheng chi
chong chou chu chua chuai chuan chuang chui chun chuo ci cong cou cu cuan cui
cun cuo
da dai dan dang dao de dei den deng di dia dian diao die ding diu dong dou du
duan dui dun duo
e ei en eng er
fa fan fang fei fen feng fo fou fu
ga gai gan gang gao ge gei gen geng gong gou gu gua guai guan guang gui gun
guo
ha hai han hang hao he hei hen heng hong hou hu hua huai huan huang hui hun
huo
ji jia jian jiang jiao jie jin jing jiong jiu ju jv juan jvan jue jve jun jvn
ka kai kan kang kao ke kei ken keng kong kou ku kua kuai kuan kuang kui kun
kuo
la lai lan lang lao le lei leng li lia lian liang liao lie lin ling liu lo long
lou lu luan lue lun luo lv lve
ma mai man mang mao me mei men meng mi mian miao mie min ming miu mo mou mu
na nai nan nang nao ne nei nen neng ni nian niang niao nie nin ning niu nong
nou nu nuan nuo nv nve
o ou
pa pai pan pang pao pei pen peng pi pian piao pie pin ping po pou pu
qi qia qian qiang qiao qie qin qing qiong qiu qu qv quan qvan que qve qun qvn
ran rang rao re ren reng ri rong rou ru rua ruan rui run ruo
sa sai san sang sao se sen seng sha shai shan shang shao she shei shen sheng
shi shou shu shua shuai shuan shuang shui shun shuo si song sou su suan sui
sun suo
ta tai tan tang tao te teng ti tian tiao tie ting tong tou tu tua tuan tui tun
tuo
wa wai wan wang wei wen weng wo wu
xi xia xian xiang xiao xie xin xing xiong xiu xu xv xuan xvan xue xve xun xvn
ya yan yang yao ye yi yin ying yo yong you yu yv yuan yvan yue yve yun yvn
za zai zan zang zao ze zei zen zeng zha zhai zhan zhang zhao zhe zhei zhen
zheng zhi zhong zhou zhu zhua zhuai zhuan zhuang zhui zhun zhuo zi zong zou
zu zuan zui zun zuo
m n ng hm hng
]]

local set = {}
for syl in SYLLABLES:gmatch("%S+") do set[syl] = true end
M.set = set

-- Can appending one letter turn this syllable into a longer valid syllable?
-- e.g. ha -> hai/han/hang/hao, but kun is terminal.
local extendable = {}
for syl in pairs(set) do
  for c in ("abcdefghijklmnopqrstuvwxyz"):gmatch(".") do
    if set[syl .. c] then
      extendable[syl] = true
      break
    end
  end
end

local function segment(input)
  local n = #input
  local reach = { [0] = true }
  local ending = {}
  for i = 1, n do
    ending[i] = {}
    for len = 1, math.min(6, i) do
      local syl = input:sub(i - len + 1, i)
      if set[syl] and reach[i - len] then
        reach[i] = true
        ending[i][syl] = true
      end
    end
  end
  return reach[n] == true, ending
end

local function full_terminal(input)
  local full, ending = segment(input)
  if not full then return false, false end
  for syl in pairs(ending[#input] or {}) do
    if not extendable[syl] then
      return true, true
    end
  end
  return false, true
end

-- Returns: terminal, segmented, extendable_with_one_letter.
-- The expensive extendability probe is only done for incomplete input.
function M.classify(input)
  local terminal, full = full_terminal(input)
  if full then return terminal, true, false end
  local can_extend = false
  for c in ("abcdefghijklmnopqrstuvwxyz"):gmatch(".") do
    if segment(input .. c) then
      can_extend = true
      break
    end
  end
  return false, false, can_extend
end

-- Choose one likely next letter that turns an incomplete prefix into a
-- complete word.  The priority order is a small heuristic (final syllables
-- ending in -e/-n/-o/-i are common); it is only used for speculative
-- prefetching, never for correctness.
local NEXT_PRIORITY = "enoiuagrhsvybdjkmlqtwxzcfp"

function M.predict_next(input)
  for c in NEXT_PRIORITY:gmatch(".") do
    local terminal, full = full_terminal(input .. c)
    if full and terminal then
      return input .. c
    end
  end
  return nil
end

return M
