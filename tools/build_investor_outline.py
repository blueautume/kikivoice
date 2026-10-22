"""Render the short investor brief; detailed engineering drafts are separate."""
from pathlib import Path
from html import escape

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (
    SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, PageBreak,
)
from reportlab.graphics.shapes import Drawing, Rect, String, Line, Polygon
from reportlab.graphics import renderSVG
from pypdf import PdfReader

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "output"
(OUT / "pdf").mkdir(parents=True, exist_ok=True)
(OUT / "diagrams").mkdir(parents=True, exist_ok=True)
FONT = "KikiSans"
pdfmetrics.registerFont(TTFont(FONT, "/System/Library/Fonts/Supplemental/Arial Unicode.ttf"))
pdfmetrics.registerFontFamily(FONT, normal=FONT, bold=FONT, italic=FONT, boldItalic=FONT)

INK = colors.HexColor("#18253C")
MUTED = colors.HexColor("#5E6B80")
PURPLE = colors.HexColor("#6D48DD")
RULE = colors.HexColor("#DEE4EF")
PALE = colors.HexColor("#F4F6FA")
RED = colors.HexColor("#C7334D")
ORANGE = colors.HexColor("#B96B0C")
BLUE = colors.HexColor("#2566B1")
RED_BG = colors.HexColor("#FCEBF0")
ORANGE_BG = colors.HexColor("#FFF2DE")
BLUE_BG = colors.HexColor("#EAF2FF")
PAGE_W, PAGE_H = A4
WIDTH = PAGE_W - 80

styles = {
    "title": ParagraphStyle("title", fontName=FONT, fontSize=22, leading=30, textColor=INK, spaceAfter=9),
    "sub": ParagraphStyle("sub", fontName=FONT, fontSize=10, leading=15, textColor=MUTED, spaceAfter=10),
    "h2": ParagraphStyle("h2", fontName=FONT, fontSize=12, leading=18, textColor=PURPLE, spaceBefore=9, spaceAfter=6),
    "body": ParagraphStyle("body", fontName=FONT, fontSize=10, leading=16, textColor=INK, spaceAfter=7),
    "small": ParagraphStyle("small", fontName=FONT, fontSize=8.5, leading=13, textColor=MUTED, spaceAfter=5),
    "tiny": ParagraphStyle("tiny", fontName=FONT, fontSize=7.7, leading=11, textColor=MUTED, spaceAfter=3),
    "cell": ParagraphStyle("cell", fontName=FONT, fontSize=9.1, leading=13.2, textColor=INK),
    "cell_small": ParagraphStyle("cell_small", fontName=FONT, fontSize=8.5, leading=12.3, textColor=INK),
    "th": ParagraphStyle("th", fontName=FONT, fontSize=9.1, leading=13, textColor=colors.white),
}


def p(text, style="body"):
    return Paragraph(text.replace("–", "-"), styles[style])


def table(rows, widths, compact=False, priority_colors=None):
    body_style = "cell_small" if compact else "cell"
    data = [[p(str(v), "th" if i == 0 else body_style) for v in row] for i, row in enumerate(rows)]
    t = Table(data, colWidths=widths, hAlign="LEFT", repeatRows=1)
    commands = [
        ("BACKGROUND", (0, 0), (-1, 0), INK),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LEFTPADDING", (0, 0), (-1, -1), 8),
        ("RIGHTPADDING", (0, 0), (-1, -1), 8),
        ("TOPPADDING", (0, 0), (-1, -1), 7 if not compact else 5),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 7 if not compact else 5),
        ("LINEBELOW", (0, 0), (-1, 0), 0.6, INK),
        ("LINEBELOW", (0, 1), (-1, -1), 0.4, RULE),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, PALE]),
    ]
    if priority_colors:
        for row, bg in priority_colors.items():
            commands.append(("BACKGROUND", (0, row), (0, row), bg))
    t.setStyle(TableStyle(commands))
    return t


def callout(title, text, bg=BLUE_BG):
    t = Table([[p(title, "h2")], [p(text, "body")]], colWidths=[WIDTH - 24])
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), bg),
        ("LEFTPADDING", (0, 0), (-1, -1), 12),
        ("RIGHTPADDING", (0, 0), (-1, -1), 12),
        ("TOPPADDING", (0, 0), (-1, 0), 4),
        ("BOTTOMPADDING", (0, -1), (-1, -1), 7),
    ]))
    return t


def module_map():
    d = Drawing(WIDTH, 282)
    def node(x, y, w, h, title, lines, bg, accent=INK):
        d.add(Rect(x, y, w, h, rx=7, ry=7, fillColor=bg, strokeColor=None))
        d.add(String(x + w / 2, y + h - 16, title, fontName=FONT, fontSize=10.5, textAnchor="middle", fillColor=accent))
        for i, text in enumerate(lines):
            d.add(String(x + w / 2, y + h - 31 - 12*i, text, fontName=FONT, fontSize=8, textAnchor="middle", fillColor=MUTED))
    def line(x1,y1,x2,y2):
        d.add(Line(x1,y1,x2,y2,strokeColor=colors.HexColor("#AFB9CB"),strokeWidth=1))
    def arrow(x,y):
        d.add(Polygon([x-3,y+5,x+3,y+5,x,y],fillColor=colors.HexColor("#AFB9CB"),strokeColor=None))
    gap = 8
    cw = (WIDTH - 3 * gap)/4
    titles = [("iOS", "已有产品基础"), ("Android", "待建设"), ("原生鸿蒙", "待建设 / 先验证"), ("Web 管理台", "运营、审核、财务、客服")]
    for i, (title, desc) in enumerate(titles):
        x = i*(cw+gap)
        node(x, 236, cw, 44, title, [desc], BLUE_BG, BLUE)
        line(x+cw/2,236,x+cw/2,223)
    line(cw/2,223,WIDTH-cw/2,223)
    line(WIDTH/2,223,WIDTH/2,211)
    arrow(WIDTH/2,209)
    node(0,166,WIDTH,43,"自有业务后台",["统一业务规则、账号与资产；连接三端、管理台和云服务"],colors.HexColor("#EFEAFB"),PURPLE)
    dw = (WIDTH-16)/3
    line(WIDTH/2,166,WIDTH/2,159)
    line(dw/2,159,WIDTH-dw/2,159)
    for i,(title,desc) in enumerate([
        ("互动与社交", "语聊 / 直播 / 关系 / 消息"),
        ("交易与权益", "充值 / 账本 / 礼物 / 会员"),
        ("治理与运营", "审核 / 处罚 / 客服 / 数据"),
    ]):
        cx=i*(dw+8)+dw/2
        line(cx,159,cx,153)
        arrow(cx,151)
        node(i*(dw+8),107,dw,44,title,[desc],RED_BG,RED)
        line(cx,107,cx,97)
    line(dw/2,97,WIDTH-dw/2,97)
    line(WIDTH/2,97,WIDTH/2,91)
    bw=(WIDTH-8)/2
    line(bw/2,91,WIDTH-bw/2,91)
    for cx in [bw/2,WIDTH-bw/2]:
        line(cx,91,cx,84)
        arrow(cx,82)
    node(0,20,bw,62,"自有数据资产与运行底座",["用户 / 订单 / 权益 / 举报 / 运营数据", "规划：托管数据库、对象存储、备份与监控"],PALE)
    node(bw+8,20,bw,62,"云服务与外部渠道",["已用：腾讯实时音视频 / 房间与消息", "待接：审核、Push、支付及其他云资源"],PALE)
    d.add(String(0,4,"此图表达模块关系；彩色模块并不表示当前已完成。",fontName=FONT,fontSize=8,fillColor=MUTED))
    return d


def page_frame(canvas, doc):
    canvas.setFillColor(PURPLE)
    canvas.roundRect(40,PAGE_H-35,5,10,2,fill=1,stroke=0)
    canvas.setFont(FONT,8)
    canvas.setFillColor(MUTED)
    canvas.drawString(52,PAGE_H-32,"KikiTalk  /  商业版功能与投入")
    canvas.drawRightString(PAGE_W-40,PAGE_H-32,"投资沟通大纲  ·  2026.10.16")
    canvas.setStrokeColor(RULE)
    canvas.line(40,40,PAGE_W-40,40)
    canvas.setFont(FONT,7.5)
    canvas.drawString(40,27,"人民币预算估算  |  中国大陆 · 中文 · iOS / Android / HarmonyOS")
    canvas.drawRightString(PAGE_W-40,27,f"{doc.page} / 4")


story = []
story += [p("从可用原型到商业化平台", "title"), p("功能模块、建设顺序与资金投入概览", "sub")]
story += [p("面向中国大陆的中文语聊与直播社区。三端统一账号和资产，首发包含充值、礼物与会员；主界面保留“语聊/直播”和“我”。")]
story += [module_map(), Spacer(1,8)]
story += [callout("已有基础", "iOS 可用原型 + 自有基础后台 + 真实腾讯实时互动。已具备八麦房间、昵称与相册头像、资料、收藏/历史及应用内最小化恢复。")]
story += [Spacer(1,8), callout("下一轮投入解决什么", "补齐 Android / 原生鸿蒙、支付与账本、举报封禁申诉、完整消息和 Push、经营管理台，以及可验证的安全、备份与运行保障。", ORANGE_BG)]
story += [p("资产与供应商边界", "h2"), p("自有系统掌握用户、资金、权益和治理记录；音视频与即时通信继续复用腾讯能力。现有 SDK 耦合较深，保留适配层可降低未来迁移成本，但更换供应商仍需改造与验证。", "small")]
story += [p("当前基础不代表商业版已完成；本文不按代码量估算完成百分比，也不承诺现有单机的商用在线容量。", "small"), PageBreak()]

story += [p("功能模块与优先级", "title"), p("P0 公开运营/收费前完成  ·  P1 首个完整商业版配齐  ·  P2 随经营规模投入", "sub")]
modules = [
    ("P0 核心", "三端客户端", "iOS、Android、原生鸿蒙；账号资产互通、权限、后台音频、弱网与版本升级"),
    ("P0 核心", "账号与“我”", "ID 登录与恢复、昵称头像、资料、钱包/会员、设置、隐私与注销；预留 Apple 登录"),
    ("P0 核心", "语聊与直播", "发现/创建房间、八麦、房主/房管、禁言踢人、公告弹幕、基础视频直播、悬浮恢复"),
    ("P0 核心", "充值 / 礼物 / 会员", "商品、支付验单、钱包账本、权益发放、订阅到期、退款与渠道对账"),
    ("P0 核心", "内容安全 / 风控", "文字图片音视频机审、人工巡检、反骚扰反诈骗、异常交易、未成年人保护"),
    ("P0 核心", "举报 / 封禁 / 申诉", "举报受理、证据留存、分级处罚、禁言封号关房、申诉复核及跨端执行"),
    ("P0 核心", "管理台 / 基础客服", "用户房间商品订单管理、审核处置、投诉退款、角色权限、审批与操作审计"),
    ("P0 核心", "合规 / 安全 / 运维", "协议隐私、备案及适用资质、监控告警、安全防护、备份恢复、发布回滚与应急"),
    ("P1 必要", "社交与私聊", "关注粉丝、收藏历史、会话与文本图片语音消息、未读、屏蔽、陌生人准入"),
    ("P1 必要", "通知与 Push", "站内通知中心、APNs/Android 厂商/鸿蒙推送、免打扰、频控与点击跳转"),
    ("P1 必要", "日常运营中心", "Banner 公告、分类推荐、活动、主播管理、客服工单、审核队列与质检"),
    ("P1 必要", "数据与版本质量", "活跃留存、付费收入退款、用户成本、举报率；崩溃、进房与音视频质量"),
    ("P2 重要", "增长与增值体验", "邀请归因、优惠活动、装扮勋章、会员分层、主题活动、规则推荐与实验"),
    ("P2 重要", "主播 / 公会经营", "招募认证、合同排班、收益工作台、公会管理；开放现金收益则结算风控提前为 P0"),
    ("P2 重要", "容量与效率升级", "自动扩容、热点缓存、数据仓库、高级反作弊、多地域容灾与供应商迁移"),
]
rows = [["优先级", "模块", "功能范围"]] + [list(r) for r in modules]
priority_bgs = {i: RED_BG if i<=8 else ORANGE_BG if i<=12 else BLUE_BG for i in range(1,16)}
story += [table(rows,[60,105,WIDTH-165],compact=True,priority_colors=priority_bgs), Spacer(1,8)]
story += [p("开放条件：私聊开放即同步具备举报、屏蔽、反骚扰与审核；交易和处罚的基础站内通知属于 P0。首发容量验证、数据备份和故障恢复不能等到规模化后再做。", "small")]
story += [p("暂缓：复杂 PK、KTV、AI 字幕、重型算法推荐。音乐等内容授权、主播现金结算及复杂公会分成另立项。", "small"), PageBreak()]

story += [p("建设计划与一次性投入", "title"), p("基线：三端 + 业务后台 + Web 管理台 + 首发付费与内容治理闭环", "sub")]
story += [callout("建设预算约 100–270 万元", "8–10 人等效团队，4–6 个月。覆盖产品/设计、三端、后端/管理台、测试与运维协作。利用现有 iOS 和后台基础；复杂玩法与分成平台另立项。")]
story += [Spacer(1,10), table([
    ["项目", "预算", "估算口径"],
    ["研发人工", "80–210 万", "8–10 人 × 4–6 月 × 2.5–3.5 万/人月；综合成本为方案假设"],
    ["外部测试 / 合规 / 接入", "5–15 万", "预算占位；适用资质与外部专业服务按实际报价确认"],
    ["建设期云 / 设备 / 账号", "3–8 万", "仅上线前期间，与后续月度运行预算分开"],
    ["预备费", "约 9–35 万", "以上三项合计的 10%–15%"],
    ["建设合计", "约 100–270 万", "原始区间约 97–268 万；取整用于资金规划"],
], [142,90,WIDTH-232])]
story += [p("分阶段推进", "h2"), table([
    ["阶段", "交付重点"],
    ["第 1 月：范围与验证", "确认首发范围、合规/支付路径、鸿蒙八麦互通和后台音频验证、商业底座设计"],
    ["第 2–4 月：主体建设", "三端并行，支付与权益、审核举报处罚、消息通知、管理台和基础运行保障"],
    ["第 5–6 月：验收上线", "跨端联调、对账、安全与容量测试、备份恢复演练、灰度和商店发布"],
], [142,WIDTH-142],compact=True)]
story += [p("服务器与扩容路线", "h2"), p("当前是单机 API、SQLite 和本地头像，未做生产容量压测。商业版先采用托管事务数据库、对象存储及共享状态，按可用性目标配置负载均衡与多实例，再依据峰值压测投入自动扩容。媒体走腾讯网络，业务、支付与审核仍各有瓶颈。", "small")]
story += [p("鸿蒙与采购边界", "h2"), p("TRTC 已有原生鸿蒙底层支持；现有 iOS UI 无法直接复用，房管、后台音频、跨端和支付需先验证。[4][5] RTC 已用不代表审核、Push、COS、数据库和备份已开通，需逐项采购。资质、商户与商店审核可影响周期，本表是规划估算。", "small"), PageBreak()]

story += [p("月度费用与资金计划", "title"), p("分开评估云用量、团队与经营支出，避免把一台服务器的费用当作平台总成本", "sub")]
story += [p("云成本示例：语聊日活 × 30 分钟/天 × 30 天；按房间时长加权平均每房 10 人，假设每房一条混合音频连续审核。产品总 DAU 需另乘语聊参与率。本表按纯语音计算。", "small")]
story += [table([
    ["语聊日活", "月用户分钟", "套餐+语音", "假设混流审核", "其他云预算", "月云合计"],
    ["1,000", "90 万", "0.95 万", "0.30 万", "0.5–1.3 万", "1.8–2.6 万"],
    ["5,000", "450 万", "3.47 万", "1.49 万", "1.1–3.0 万", "6.1–8.0 万"],
    ["10,000", "900 万", "6.62 万", "2.97 万", "2.0–6.0 万", "11.6–15.6 万"],
], [59,75,82,91,100,WIDTH-407],compact=True)]
story += [Spacer(1,7), p("公开参考价：套餐 5,874 元/月，含 38 万音频等价分钟及对应 IM；超量音频 0.007 元/用户分钟；音频审核 0.033 元/审核分钟。[1][2][3] 套餐含量只抵扣一次。其他云预算包括业务服务器、数据库/缓存、存储/CDN、备份、监控安全及增量短信/Push/图文审核，为方案占位。", "small")]
story += [p("敏感项与边界：平均每房降为 5 人，假设混流审核费翻倍。混流能否满足治理与发言人归因需验证，逐轨审核需重算。表内不含视频、额外录制/转码/混流任务及机器人订阅费；参考套餐有 50 个未解散房间等限额，高用量行需另核峰值和升档费。", "small")]
story += [p("团队与经营支出", "h2"), table([
    ["项目", "月度预算 / 口径"],
    ["持续研发、产品、测试和运维", "4–6 人 × 2.5–3.5 万 = 10–21 万/月"],
    ["基础运营、客服与审核协作", "暂设 3–8 万/月；按时段和人工量重算，不代表全天多岗值守"],
    ["团队小计", "13–29 万/月；与建设期按不同期间计算"],
    ["另列经营专项", "获客、主播激励/分成、版权、渠道佣金、支付结算、退款欺诈、税费及行政"],
], [166,WIDTH-166],compact=True)]
story += [Spacer(1,8), callout("早期资金参考", "1,000 语聊日活下，团队 + 云约 15–32 万/月。建设期之后再留 6 个月此规模运行资金，合计约 190–462 万元；还需叠加获客、内容供给、分成、视频和收入相关支出，并考虑回款。", ORANGE_BG)]
story += [Spacer(1,5), p("经营看板：活跃留存、有效房间供给、付费转化、每付费用户收入、投诉退款、每语聊小时成本、扣除渠道/分成/用量后的贡献利润、获客回收期。", "small")]
story += [p("参考来源与估算说明", "h2")]
sources = [
    ('[1] 腾讯套餐', 'https://cloud.tencent.com.cn/document/product/647/105439'),
    ('[2] 语音计费', 'https://cloud.tencent.com/document/product/647/44248'),
    ('[3] 音频审核', 'https://cloud.tencent.com/document/product/1124/135178'),
    ('[4] SDK 平台', 'https://cloud.tencent.com/document/product/647/105438'),
    ('[5] 鸿蒙接入', 'https://cloud.tencent.com/document/product/647/130532'),
    ('[6] Apple 规则', 'https://developer.apple.com/app-store/review/guidelines/'),
    ('[7] 直播打赏规定', 'https://www.cac.gov.cn/2026-04/13/c_1777815804150225.htm'),
]
story += [p('　'.join(f'<link href="{escape(url,quote=True)}" color="#5C40BE">{label}</link>' for label,url in sources),"tiny")]
story += [p("2026-10-16 核对公开价格。费率、授权与配额以采购时为准；数字商品按适用渠道规则设计，不统一假定 30% 佣金。[6] 大陆备案、适用资质及打赏/未成年人要求由专业人员核对。[7] 团队成本和其他预算为本方案假设，非固定报价。", "tiny")]

pdf_path = OUT / "pdf" / "KikiTalk-Investor-Outline.pdf"
doc = SimpleDocTemplate(str(pdf_path), pagesize=A4, rightMargin=40, leftMargin=40, topMargin=58, bottomMargin=54, title="KikiTalk 商业版功能与投入大纲", author="KikiTalk", pageCompression=1)
doc.build(story, onFirstPage=page_frame, onLaterPages=page_frame)
pages = len(PdfReader(str(pdf_path)).pages)
if pages != 4:
    raise RuntimeError(f"Expected 4 pages, got {pages}; adjust layout before delivery")
svg_path = OUT / "diagrams" / "kikitalk-commercial-overview.svg"
renderSVG.drawToFile(module_map(), str(svg_path))
svg_text = svg_path.read_text().replace("font-family: KikiSans", "font-family: 'Arial Unicode MS', 'PingFang SC', sans-serif")
svg_text = svg_text.replace("<title>...</title>", "<title>KikiTalk 商业版整体模块图</title>")
svg_text = svg_text.replace("<desc>...</desc>", "<desc>三端客户端和管理台连接自有业务后台、数据资产、腾讯实时服务与其他外部渠道。</desc>")
svg_path.write_text(svg_text)
print(f"Created {pages}-page PDF: {pdf_path}")
print(f"Created module map: {svg_path}")
