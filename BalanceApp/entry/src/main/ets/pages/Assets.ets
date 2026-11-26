/*
 * Assets.ets —— 资产监控（服务商余额 Dashboard）
 *
 * 由原 Index 页迁出，作为「设置 > 资产监控」的独立详情页：
 * 顶部总资产 Hero 卡 + 服务商余额卡片列表 + 添加服务商弹窗 + 空态引导。
 *
 * Reason: 查询为 GET 幂等操作，无需幂等 key；用 globalSession 自增 token 隔离
 *   新旧异步回调，防止慢返回污染新状态（P0 session token 隔离）。
 * 安全: Key 仅存本地 Preferences（分供应商存储）、不打明文日志、不进 git。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import {
  PROVIDERS, ProviderDefinition, ProviderCategory, BalanceInfo,
  findProvider, currencySymbol, categoryLabel, unitLabel,
  formatAmountText,
} from '../services/ProviderRegistry';
import { fetchProviderBalance, ProviderBalanceResult } from '../services/BalanceService';
import { skinColor } from '../services/SkinService';

const DOMAIN = 0x0000;
const TAG = 'BalanceAssets';
const PREFS_NAME = 'balance_prefs';
const KEY_ADDED_IDS = 'addedIds';

interface ProviderRecord {
  defId: string;
  apiKey: string;
  info?: BalanceInfo;
  error?: string;
  loading: boolean;
  updatedAt: string;
}

interface CurrencyGroup {
  currency: string;
  available: number;
  total: number;
  used: number;
}

/** Reason: 日志一律用掩码，原始 key 永不进日志与界面回显。 */
function maskKey(key: string): string {
  const k: string = key.trim();
  if (k.length <= 6) {
    return '***';
  }
  return `${k.slice(0, 3)}***${k.slice(-2)}`;
}

function formatToday(): string {
  const d: Date = new Date();
  return `${d.getMonth() + 1}月${d.getDate()}日`;
}

@Entry
@Component
struct Assets {
  /** 皮肤版本号：皮肤或明暗切换时自增（SkinService），驱动本组件按新调色板重绘。 */
  @StorageProp('skin_version') skinVersion: number = 0;
  @State records: ProviderRecord[] = [];
  @State showAddSheet: boolean = false;
  @State addQuery: string = '';
  @State editTargetId: string = '';
  @State editKeyText: string = '';
  @State editError: string = '';
  @State showKeyInDialog: boolean = false;
  @State actionTargetId: string = '';
  @State globalSession: number = 0;
  @State refreshingAll: boolean = false;
  @State heroGroups: CurrencyGroup[] = [];
  // 添加服务商：0=未添加，1=已添加
  @State addTab: number = 0;
  private prefs: preferences.Preferences | undefined = undefined;

  private goBack(): void {
    try {
      this.getUIContext().getRouter().back();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'back failed: %{public}s', String(err));
    }
  }

  // ── 持久化 ──

  private prefsKeyFor(id: string): string {
    return `key_${id}`;
  }

  async aboutToAppear(): Promise<void> {
    try {
      const uiCtx = this.getUIContext();
      const hostCtx = uiCtx.getHostContext() as common.UIAbilityContext;
      this.prefs = await preferences.getPreferences(hostCtx, { name: PREFS_NAME });
      const curPrefs: preferences.Preferences = this.prefs as preferences.Preferences;
      const idsVal: preferences.ValueType = await curPrefs.get(KEY_ADDED_IDS, '');
      const loaded: ProviderRecord[] = [];
      if (typeof idsVal === 'string') {
        const idsStr: string = idsVal as string;
        if (idsStr.length > 0) {
          const ids: string[] = idsStr.split(',');
          let i: number = 0;
          while (i < ids.length) {
            const id: string = ids[i].trim();
            const def: ProviderDefinition | undefined = findProvider(id);
            if (id.length > 0 && def !== undefined) {
              const kv: preferences.ValueType = await curPrefs.get(this.prefsKeyFor(id), '');
              let savedKey: string = '';
              if (typeof kv === 'string') {
                savedKey = kv as string;
              }
              const rec: ProviderRecord = {
                defId: id, apiKey: savedKey, info: undefined,
                error: undefined, loading: false, updatedAt: '',
              };
              loaded.push(rec);
            }
            i += 1;
          }
        }
      }
      this.records = loaded;
      this.updateHero();
      hilog.info(DOMAIN, TAG, 'Loaded %{public}d providers from prefs', this.records.length);
    } catch (err) {
      const msg: string = err instanceof Error ? err.message : 'unknown';
      hilog.error(DOMAIN, TAG, 'Load prefs failed: %{public}s', msg);
    }
    // 对齐智额 _loadBalances：进页自动拉取已添加供应商余额。
    if (this.records.length > 0) {
      this.refreshAll();
    }
  }

  private async savePrefs(): Promise<void> {
    try {
      if (this.prefs === undefined) {
        const uiCtx = this.getUIContext();
        const hostCtx = uiCtx.getHostContext() as common.UIAbilityContext;
        this.prefs = await preferences.getPreferences(hostCtx, { name: PREFS_NAME });
      }
      const curPrefs: preferences.Preferences = this.prefs as preferences.Preferences;
      let ids: string = '';
      let i: number = 0;
      while (i < this.records.length) {
        if (i > 0) {
          ids += ',';
        }
        ids += this.records[i].defId;
        // NOTE: Preferences 为本地明文 KV（系统级加密依赖设备锁屏）；不打日志、不进 git。
        await curPrefs.put(this.prefsKeyFor(this.records[i].defId), this.records[i].apiKey);
        i += 1;
      }
      await curPrefs.put(KEY_ADDED_IDS, ids);
      await curPrefs.flush();
    } catch (err) {
      const msg: string = err instanceof Error ? err.message : 'unknown';
      hilog.error(DOMAIN, TAG, 'Save prefs failed: %{public}s', msg);
    }
  }

  // ── 查询 ──

  /** Reason: @State 仅观察数组本身变化，深层字段改动后需重建数组引用推 UI 刷新。 */
  private refreshView(): void {
    const copy: ProviderRecord[] = [];
    let i: number = 0;
    while (i < this.records.length) {
      const o: ProviderRecord = this.records[i];
      copy.push({
        defId: o.defId, apiKey: o.apiKey, info: o.info,
        error: o.error, loading: o.loading, updatedAt: o.updatedAt,
      });
      i += 1;
    }
    this.records = copy;
  }

  private recordIndex(id: string): number {
    let i: number = 0;
    while (i < this.records.length) {
      if (this.records[i].defId === id) {
        return i;
      }
      i += 1;
    }
    return -1;
  }

  private async queryOne(id: string, sid: number): Promise<void> {
    const idx: number = this.recordIndex(id);
    if (idx < 0) {
      return;
    }
    const def: ProviderDefinition | undefined = findProvider(id);
    if (def === undefined) {
      return;
    }
    this.records[idx].loading = true;
    this.records[idx].error = undefined;
    this.refreshView();
    hilog.info(DOMAIN, TAG, 'Query %{public}s credential=%{public}s',
      (def as ProviderDefinition).name, maskKey(this.records[idx].apiKey));
    try {
      const res: ProviderBalanceResult = await fetchProviderBalance(id, this.records[idx].apiKey);
      if (sid !== this.globalSession) {
        hilog.info(DOMAIN, TAG, 'Stale response dropped, sid=%{public}d', sid);
        return;
      }
      const at: number = this.recordIndex(id);
      if (at < 0) {
        return;
      }
      if (res.success) {
        this.records[at].info = res.info as BalanceInfo;
        this.records[at].error = undefined;
        this.records[at].updatedAt = (res.info as BalanceInfo).updatedAt;
        this.updateHero();
        this.refreshView();
      } else {
        this.records[at].info = undefined;
        this.records[at].error = res.error !== undefined ? (res.error as string) : '查询失败';
        this.updateHero();
        this.refreshView();
      }
    } catch (err) {
      if (sid !== this.globalSession) {
        return;
      }
      const msg: string = err instanceof Error ? err.message : 'request failed';
      const at: number = this.recordIndex(id);
      // 瞬时失败保留上次成功值（keep-last-good，内存级）。
      if (at >= 0 && this.records[at].info === undefined) {
        this.records[at].error = `网络异常（可重试）：${msg}`;
      } else if (at >= 0) {
        this.records[at].error = `网络异常（可重试，已保留上次成功结果）：${msg}`;
      }
      if (at >= 0) {
        this.refreshView();
      }
      hilog.error(DOMAIN, TAG, 'Query transient failed: %{public}s', msg);
    } finally {
      if (sid === this.globalSession) {
        const at: number = this.recordIndex(id);
        if (at >= 0) {
          this.records[at].loading = false;
          this.refreshView();
        }
      }
    }
  }

  private async refreshAll(): Promise<void> {
    // session token 隔离：每次整轮刷新自增，旧回调直接丢弃。
    this.globalSession += 1;
    const sid: number = this.globalSession;
    this.refreshingAll = true;
    let i: number = 0;
    while (i < this.records.length) {
      await this.queryOne(this.records[i].defId, sid);
      if (sid !== this.globalSession) {
        break;
      }
      i += 1;
    }
    if (sid === this.globalSession) {
      this.refreshingAll = false;
    }
  }

  private refreshOne(id: string): void {
    this.globalSession += 1;
    const sid: number = this.globalSession;
    // Reason: 单卡刷新会作废进行中的整轮刷新；整轮刷新的收尾条件 sid === globalSession
    //   将不再成立，若不在此复位 refreshingAll，「刷新全部」按钮会永久置灰。
    this.refreshingAll = false;
    this.queryOne(id, sid);
  }

  // ── 添加 / 编辑 / 删除 ──

  private openAddSheet(): void {
    this.addQuery = '';
    this.addTab = 0;
    this.showAddSheet = true;
  }

  private onPickProvider(id: string): void {
    this.showAddSheet = false;
    const idx: number = this.recordIndex(id);
    this.editTargetId = id;
    this.editKeyText = idx >= 0 ? this.records[idx].apiKey : '';
    this.editError = '';
    this.showKeyInDialog = false;
  }

  private async confirmEditKey(): Promise<void> {
    const id: string = this.editTargetId;
    const key: string = this.editKeyText.trim();
    if (id.length === 0) {
      return;
    }
    const def: ProviderDefinition | undefined = findProvider(id);
    if (def === undefined) {
      return;
    }
    // Business Rule: 边界处强制校验，不合法直接拒绝、不进网络层。
    if (key.length === 0) {
      this.editError = '请粘贴 API Key';
      return;
    }
    if (key.length < 4) {
      this.editError = 'API Key 至少 4 个字符';
      return;
    }
    this.editError = '';
    const idx: number = this.recordIndex(id);
    if (idx < 0) {
      const rec: ProviderRecord = {
        defId: id, apiKey: key, info: undefined,
        error: undefined, loading: false, updatedAt: '',
      };
      this.records.push(rec);
    } else {
      this.records[idx].apiKey = key;
    }
    this.editTargetId = '';
    this.editKeyText = '';
    await this.savePrefs();
    this.refreshOne(id);
  }

  private cancelEditKey(): void {
    this.editTargetId = '';
    this.editKeyText = '';
    this.editError = '';
  }

  private async removeProvider(id: string): Promise<void> {
    this.globalSession += 1;
    const kept: ProviderRecord[] = [];
    let i: number = 0;
    while (i < this.records.length) {
      if (this.records[i].defId !== id) {
        kept.push(this.records[i]);
      }
      i += 1;
    }
    this.records = kept;
    this.updateHero();
    try {
      if (this.prefs !== undefined) {
        const curPrefs: preferences.Preferences = this.prefs as preferences.Preferences;
        await curPrefs.delete(this.prefsKeyFor(id));
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Delete pref failed');
    }
    await this.savePrefs();
  }

  // ── 汇总（对齐智额 HeroStatsCard；多币种分币种行，避免误加） ──

  private currencyGroups(): CurrencyGroup[] {
    const groups: CurrencyGroup[] = [];
    let i: number = 0;
    while (i < this.records.length) {
      const info: BalanceInfo | undefined = this.records[i].info;
      if (info !== undefined) {
        const cur: string = (info as BalanceInfo).currency;
        let gi: number = 0;
        let found: number = -1;
        while (gi < groups.length) {
          if (groups[gi].currency === cur) {
            found = gi;
            break;
          }
          gi += 1;
        }
        if (found < 0) {
          groups.push({ currency: cur, available: 0, total: 0, used: 0 });
          found = groups.length - 1;
        }
        groups[found].available += (info as BalanceInfo).available;
        groups[found].total += (info as BalanceInfo).total;
        groups[found].used += (info as BalanceInfo).used;
      }
      i += 1;
    }
    return groups;
  }

  private filteredProviders(cat: ProviderCategory): ProviderDefinition[] {
    const out: ProviderDefinition[] = [];
    const q: string = this.addQuery.trim().toLowerCase();
    let i: number = 0;
    while (i < PROVIDERS.length) {
      const p: ProviderDefinition = PROVIDERS[i];
      if (p.category === cat) {
        // addTab: 0=未添加，1=已添加。
        const added: boolean = this.recordIndex(p.id) >= 0;
        if (this.addTab === 0 && added) {
          i += 1;
          continue;
        }
        if (this.addTab === 1 && !added) {
          i += 1;
          continue;
        }
        if (q.length === 0 || p.name.toLowerCase().includes(q) || p.id.toLowerCase().includes(q)) {
          out.push(p);
        }
      }
      i += 1;
    }
    return out;
  }

  private editTargetName(): string {
    const def: ProviderDefinition | undefined = findProvider(this.editTargetId);
    if (def === undefined) {
      return '';
    }
    return (def as ProviderDefinition).name;
  }

  /** Reason: @Builder 内只允许 UI 组件语法，取值逻辑收敛到普通方法供表达式调用。 */
  private updateHero(): void {
    this.heroGroups = this.currencyGroups();
  }

  private cardName(rec: ProviderRecord): string {
    const def: ProviderDefinition | undefined = findProvider(rec.defId);
    if (def === undefined) {
      return rec.defId;
    }
    return (def as ProviderDefinition).name;
  }

  /** 注册表只有 DeepSeek；$r 须字面量，保留静态映射。 */
  private providerIcon(id: string): Resource {
    return $r('app.media.deepseek');
  }

  /** 数据指纹 key，loading/info/error/时间任一变化即视为新条目。 */
  private cardVersionKey(rec: ProviderRecord): string {
    let flag: string = 'N';
    if (rec.loading) {
      flag = 'L';
    } else if (rec.info !== undefined) {
      flag = 'I';
    } else if (rec.error !== undefined) {
      flag = 'E';
    }
    return `${rec.defId}|${flag}|${rec.updatedAt}`;
  }

  private editCredentialNoun(): string {
    return 'Key';
  }

  private editPlaceholder(): string {
    return '粘贴 API Key';
  }

  private editStorageHint(): string {
    return 'Key 仅存储在本地设备';
  }

  private heroMixedLabel(): string {
    return '多币种组合';
  }

  // ── 构建 ──

  build() {
    Stack() {
      Column() {
        // 顶部导航栏：返回 + 标题 + 日期
        Row() {
          Text('‹')
            .fontSize(28)
            .fontColor(skinColor('text_primary'))
            .width(42)
            .height(42)
            .textAlign(TextAlign.Center)
            .backgroundColor(skinColor('surface_alt'))
            .borderRadius(21)
            .onClick(() => {
              this.goBack();
            })
          Text('资产监控')
            .fontSize(19)
            .fontWeight(FontWeight.Bold)
            .fontColor(skinColor('text_title'))
          Blank()
          Text(formatToday())
            .fontSize(13)
            .fontColor(skinColor('text_muted'))
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .backgroundColor(skinColor('surface_alt'))
            .borderRadius(14)
        }
        .width('92%')
        .height(60)

        Column() {
          // 顶栏：刷新全部 + 添加
          Row() {
            Blank()
            if (this.records.length > 0) {
              Button('刷新全部')
                .fontSize(14)
                .height(40)
                .backgroundColor(skinColor('surface'))
                .fontColor(skinColor('text_secondary'))
                .border({ width: 1, color: skinColor('border_card') })
                .borderRadius(14)
                .enabled(!this.refreshingAll)
                .margin({ right: 8 })
                .onClick(() => {
                  this.refreshAll();
                })
            }
            Button('＋ 添加')
              .fontSize(14)
              .height(40)
              .backgroundColor(skinColor('accent_solid'))
              .fontColor(skinColor('accent_contrast'))
              .borderRadius(14)
              .onClick(() => {
                this.openAddSheet();
              })
          }
          .width('92%')
          .margin({ top: 12, bottom: 12 })

          if (this.records.length === 0) {
            // 空态引导（对齐智额 OnboardingSheet）
            Column() {
              Text('B')
                .fontSize(24)
                .fontWeight(FontWeight.Medium)
                .fontColor(skinColor('accent'))
                .width(60)
                .height(60)
                .textAlign(TextAlign.Center)
                .backgroundColor(skinColor('icon_tile'))
                .border({ width: 1, color: skinColor('accent_outline') })
                .borderRadius(30)
              Text('暂无服务商')
                .fontSize(21)
                .fontWeight(FontWeight.Medium)
                .fontColor(skinColor('text_title'))
                .margin({ top: 24, bottom: 8 })
              Text('添加 API 供应商并填写 Key，即可透视多家余额')
                .fontSize(14)
                .fontColor(skinColor('text_muted'))
                .margin({ bottom: 24 })
              Button('添加服务商')
                .width('64%')
                .height(48)
                .backgroundColor(skinColor('accent_solid'))
                .fontColor(skinColor('accent_contrast'))
                .borderRadius(16)
                .onClick(() => {
                  this.openAddSheet();
                })
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
          } else {
            Scroll() {
              Column() {
                this.HeroCard()
                // Reason: key 携带数据版本号，数据变化即重建条目，杜绝 ForEach 复用旧快照。
                ForEach(this.records, (rec: ProviderRecord) => {
                  this.ProviderCard(rec)
                }, (rec: ProviderRecord) => this.cardVersionKey(rec))
              }
              .width('100%')
            }
            .width('100%')
            .layoutWeight(1)
            .scrollBar(BarState.Off)
          }
        }
        .width('100%')
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(skinColor('page_bg'))

      // 添加服务商弹窗（底部上滑 + 点空白处收回）
      if (this.showAddSheet) {
        Column() {
          Blank()
            .layoutWeight(1)
            .onClick(() => {
              this.showAddSheet = false;
            })
            .layoutWeight(1)
            .onClick(() => {
              this.showAddSheet = false;
            })
          Column() {
            Text('添加服务商')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .margin({ top: 16, bottom: 8 })
            TextInput({ placeholder: '搜索服务商...', text: this.addQuery })
              .width('92%')
              .height(46)
              .backgroundColor(skinColor('input_bg'))
              .borderRadius(14)
              .border({ width: 1, color: skinColor('border_card') })
              .margin({ bottom: 8 })
              .onChange((v: string) => {
                this.addQuery = v;
              })
            // 已添加 / 未添加分段选择
            Row() {
              Text('未添加')
                .fontSize(13)
                .fontColor(this.addTab === 0 ? skinColor('accent_contrast') : skinColor('text_primary'))
                .padding({ left: 16, right: 16, top: 6, bottom: 6 })
                .backgroundColor(this.addTab === 0 ? skinColor('accent_solid') : skinColor('fill'))
                .borderRadius(16)
                .margin({ right: 8 })
                .onClick(() => {
                  this.addTab = 0;
                })
              Text('已添加')
                .fontSize(13)
                .fontColor(this.addTab === 1 ? skinColor('accent_contrast') : skinColor('text_primary'))
                .padding({ left: 16, right: 16, top: 6, bottom: 6 })
                .backgroundColor(this.addTab === 1 ? skinColor('accent_solid') : skinColor('fill'))
                .borderRadius(16)
                .onClick(() => {
                  this.addTab = 1;
                })
            }
            .width('92%')
            .margin({ bottom: 8 })
            Scroll() {
              Column() {
                this.ProviderGroup(ProviderCategory.CnOfficial)
              }
              .width('100%')
            }
            .layoutWeight(1)
            Button('取消')
              .width('92%')
              .height(44)
              .backgroundColor(skinColor('fill'))
              .fontColor(skinColor('text_primary'))
              .borderRadius(14)
              .margin({ top: 8, bottom: 16 })
              .onClick(() => {
                this.showAddSheet = false;
              })
          }
          .width('100%')
          .height('70%')
          .backgroundColor(skinColor('surface'))
          .borderRadius({ topLeft: 28, topRight: 28 })
          .border({ width: 1, color: skinColor('border_soft') })
          .shadow({ radius: 28, color: 'rgba(20,18,14,0.18)', offsetX: 0, offsetY: 10 })
          .transition(TransitionEffect.translate({ y: 360 }).animation({ duration: 260, curve: Curve.EaseOut }))
        }
        .width('100%')
        .height('100%')
        .backgroundColor(skinColor('overlay_scrim'))
        .transition(TransitionEffect.opacity(0).animation({ duration: 200 }))
      }

      // 卡片长按操作菜单（自绘底部面板 + 点空白收回）
      if (this.actionTargetId !== '') {
        Column() {
          Blank()
            .layoutWeight(1)
            .onClick(() => {
              this.closeCardActions();
            })
          Column() {
            Text(this.actionTargetName())
              .fontSize(17)
              .fontWeight(FontWeight.Bold)
              .margin({ top: 16, bottom: 4 })
            Column() {
              this.ActionRow('刷', '刷新余额', '重新查询该服务商的最新余额', '#80633B', false, () => {
                const id: string = this.actionTargetId;
                this.closeCardActions();
                this.refreshOne(id);
              })
              this.ActionRow('键', this.actionCredentialLabel(), this.actionCredentialDesc(), '#80633B', false, () => {
                const id: string = this.actionTargetId;
                this.closeCardActions();
                this.onPickProvider(id);
              })
              this.ActionRow('删', '移除服务商', '删除卡片与本地保存的 Key', '#A34F44', true, () => {
                const id: string = this.actionTargetId;
                this.closeCardActions();
                this.removeProvider(id);
              })
            }
            .width('92%')
            Button('取消')
              .width('92%')
              .height(44)
              .backgroundColor(skinColor('fill'))
              .fontColor(skinColor('text_primary'))
              .borderRadius(14)
              .margin({ top: 8, bottom: 16 })
              .onClick(() => {
                this.closeCardActions();
              })
          }
          .width('100%')
          .backgroundColor(skinColor('surface'))
          .borderRadius({ topLeft: 28, topRight: 28 })
          .border({ width: 1, color: skinColor('border_soft') })
          .shadow({ radius: 28, color: 'rgba(20,18,14,0.18)', offsetX: 0, offsetY: 10 })
          .transition(TransitionEffect.translate({ y: 360 }).animation({ duration: 260, curve: Curve.EaseOut }))
        }
        .width('100%')
        .height('100%')
        .backgroundColor(skinColor('overlay_scrim'))
        .transition(TransitionEffect.opacity(0).animation({ duration: 200 }))
      }

      // Key 输入弹窗（添加/更新共用）
      if (this.editTargetId !== '') {
        Column() {
          Blank()
          Column() {
            Text(`设置 ${this.editTargetName()} 的${this.editCredentialNoun()}`)
              .fontSize(17)
              .fontWeight(FontWeight.Bold)
              .margin({ top: 20, bottom: 4 })
            Text(this.editStorageHint())
              .fontSize(13)
              .fontColor(skinColor('accent'))
              .margin({ bottom: 12 })
            Row() {
              TextInput({ placeholder: this.editPlaceholder(), text: this.editKeyText })
                .type(this.showKeyInDialog ? InputType.Normal : InputType.Password)
                .height(48)
                .backgroundColor(skinColor('input_bg'))
                .borderRadius(14)
                .border({ width: 1, color: skinColor('border_card') })
                .layoutWeight(1)
                .onChange((v: string) => {
                  this.editKeyText = v;
                })
              Button(this.showKeyInDialog ? '隐藏' : '显示')
                .fontSize(13)
                .backgroundColor(skinColor('accent_soft'))
                .fontColor(skinColor('accent'))
                .borderRadius(12)
                .margin({ left: 8 })
                .onClick(() => {
                  this.showKeyInDialog = !this.showKeyInDialog;
                })
            }
            .width('90%')
            .margin({ bottom: 16 })
            if (this.editError.length > 0) {
              Text(this.editError)
                .fontSize(12)
                .fontColor(skinColor('danger_text'))
                .width('90%')
                .margin({ bottom: 10 })
            }
            Row() {
              Button('取消')
                .layoutWeight(1)
                .backgroundColor(skinColor('fill'))
                .fontColor(skinColor('text_primary'))
                .borderRadius(14)
                .onClick(() => {
                  this.cancelEditKey();
                })
              Button('保存')
                .layoutWeight(1)
                .backgroundColor(skinColor('accent_solid'))
                .fontColor(skinColor('accent_contrast'))
                .borderRadius(14)
                .margin({ left: 8 })
                .enabled(this.editKeyText.trim().length >= 4)
                .onClick(() => {
                  this.confirmEditKey();
                })
            }
            .width('90%')
            .margin({ bottom: 20 })
          }
          .width('88%')
          .backgroundColor(skinColor('surface'))
          .borderRadius(24)
          .border({ width: 1, color: skinColor('border_soft') })
          .shadow({ radius: 24, color: 'rgba(20,18,14,0.16)', offsetX: 0, offsetY: 8 })
          Blank()
        }
        .width('100%')
        .height('100%')
        .backgroundColor(skinColor('overlay_scrim'))
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  HeroCard() {
    Column() {
      Text('总资产')
        .fontSize(13)
        .fontColor(skinColor('hero_muted'))
        .width('100%')
        .margin({ bottom: 12 })
      if (this.heroGroups.length === 0) {
        Text('查询后此处汇总可用余额')
          .fontSize(15)
          .fontColor(skinColor('hero_muted'))
          .width('100%')
      } else if (this.heroGroups.length > 1) {
        // Reason: 多币种不做跨币种相加（智额仅提示 mixedCurrency），分币种列示避免误导；
        //   积分也按同一规则单列，不与人民币混算。
        Text(this.heroMixedLabel())
          .fontSize(27)
          .fontWeight(FontWeight.Bolder)
          .fontColor(skinColor('hero_accent'))
          .width('100%')
          .margin({ bottom: 8 })
        ForEach(this.heroGroups, (g: CurrencyGroup) => {
          Text(`可用 ${currencySymbol(g.currency)}${formatAmountText(g.currency, g.available)} ${unitLabel(g.currency)}`)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(skinColor('hero_text'))
            .width('100%')
            .margin({ bottom: 4 })
        }, (g: CurrencyGroup) => g.currency)
      } else {
        Row() {
          Text(`${currencySymbol(this.heroGroups[0].currency)}${formatAmountText(this.heroGroups[0].currency, this.heroGroups[0].available)}`)
            .fontSize(36)
            .fontWeight(FontWeight.Bolder)
            .fontColor(skinColor('hero_accent'))
          Text(` ${unitLabel(this.heroGroups[0].currency)}`)
            .fontSize(14)
            .fontColor(skinColor('hero_muted'))
        }
        .width('100%')
      }
      // 各家分布（对齐智额 providerBalances）
      ForEach(this.records, (rec: ProviderRecord) => {
        this.HeroRow(rec)
      }, (rec: ProviderRecord) => this.cardVersionKey(rec))
    }
    .width('92%')
    .padding({ left: 20, right: 20, top: 22, bottom: 20 })
    .margin({ top: 8, bottom: 14 })
    .backgroundColor(skinColor('hero_bg'))
    .borderRadius(26)
    .border({ width: 1, color: 'rgba(217,188,131,0.22)' })
    .shadow({ radius: 20, color: 'rgba(35,30,20,0.16)', offsetX: 0, offsetY: 8 })
  }

  @Builder
  HeroRow(rec: ProviderRecord) {
    Row() {
      Text(this.cardName(rec))
        .fontSize(13)
        .fontColor(skinColor('hero_muted'))
      Blank()
      if (rec.info !== undefined) {
        Text(`${currencySymbol((rec.info as BalanceInfo).currency)}${formatAmountText((rec.info as BalanceInfo).currency, (rec.info as BalanceInfo).available)}`)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(skinColor('hero_text'))
      } else if (rec.loading) {
        Text('查询中…')
          .fontSize(13)
          .fontColor(skinColor('hero_muted'))
      } else {
        Text(rec.error !== undefined ? '失败' : '未查询')
          .fontSize(13)
          .fontColor(skinColor('danger_text'))
      }
    }
    .width('100%')
    .margin({ top: 6 })
  }

  @Builder
  ProviderCard(rec: ProviderRecord) {
    Column() {
      Row() {
        // 品牌图标（本地资源；智额用 assets/logos，这里是鸿蒙 media 资源）
        Image(this.providerIcon(rec.defId))
        .width(48)
        .height(48)
        .borderRadius(16)
        .backgroundColor(skinColor('icon_tile'))
        Column() {
          Text(this.cardName(rec))
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(skinColor('text_title'))
          if (rec.updatedAt.length > 0) {
            Text(rec.updatedAt)
              .fontSize(12)
              .fontColor(skinColor('text_muted'))
          }
        }
        .margin({ left: 12 })
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        if (rec.loading) {
          LoadingProgress()
            .width(24)
            .height(24)
        }
      }
      .width('100%')
      .margin({ bottom: 10 })

      if (rec.info !== undefined) {
        Row() {
          Text(`${currencySymbol((rec.info as BalanceInfo).currency)}${formatAmountText((rec.info as BalanceInfo).currency, (rec.info as BalanceInfo).available)}`)
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor(skinColor('text_title'))
          Text(` ${unitLabel((rec.info as BalanceInfo).currency)}`)
            .fontSize(13)
            .fontColor(skinColor('text_muted'))
        }
        .width('100%')
        .margin({ bottom: 10 })
      } else if (rec.error !== undefined) {
        Text(rec.error as string)
          .fontSize(14)
          .fontColor(skinColor('danger_text'))
          .width('100%')
          .margin({ bottom: 10 })
      } else if (!rec.loading) {
        Text('尚未查询，点击卡片刷新获取余额')
          .fontSize(14)
          .fontColor(skinColor('text_faint'))
          .width('100%')
          .margin({ bottom: 10 })
      }
    }
    .width('92%')
    .padding(18)
    .margin({ bottom: 12 })
    .backgroundColor(skinColor('surface'))
    .border({ width: 1, color: skinColor('border_soft') })
    .borderRadius(22)
    .shadow({ radius: 14, color: 'rgba(35,30,20,0.07)', offsetX: 0, offsetY: 4 })
    // Business Rule: 单击=刷新（只读无副作用），长按=操作菜单（刷新/换Key/移除三选一）。
    .onClick(() => {
      if (!rec.loading) {
        this.refreshOne(rec.defId);
      }
    })
    .gesture(
      LongPressGesture({ repeat: false })
        .onAction(() => {
          this.showCardActions(rec.defId);
        })
    )
  }

  /** 长按卡片操作菜单：自绘底部面板（系统 ActionSheet 样式太素）。 */
  private showCardActions(id: string): void {
    this.actionTargetId = id;
  }

  private closeCardActions(): void {
    this.actionTargetId = '';
  }

  private actionTargetName(): string {
    const def: ProviderDefinition | undefined = findProvider(this.actionTargetId);
    if (def === undefined) {
      return '';
    }
    return (def as ProviderDefinition).name;
  }

  private actionCredentialLabel(): string {
    return '更换 Key';
  }

  private actionCredentialDesc(): string {
    return '更新本地保存的 API Key';
  }

  @Builder
  ActionRow(badge: string, title: string, desc: string, color: string, isLast: boolean, onTap: () => void) {
    Row() {
      Text(badge)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .width(40)
        .height(40)
        .textAlign(TextAlign.Center)
        .backgroundColor(color)
        .borderRadius(12)
      Column() {
        Text(title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
        Text(desc)
          .fontSize(12)
          .fontColor(skinColor('text_muted'))
      }
      .margin({ left: 12 })
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Text('›')
        .fontSize(20)
        .fontColor(skinColor('icon_muted'))
    }
    .width('100%')
    .padding(10)
    .margin({ bottom: isLast ? 0 : 6 })
    .backgroundColor(skinColor('surface_row'))
    .borderRadius(12)
    .onClick(onTap)
  }

  @Builder
  ProviderGroup(cat: ProviderCategory) {
    Column() {
      if (this.filteredProviders(cat).length > 0) {
        Text(categoryLabel(cat))
          .fontSize(12)
          .fontColor(skinColor('text_muted'))
          .width('92%')
          .margin({ top: 8, bottom: 4 })
        ForEach(this.filteredProviders(cat), (p: ProviderDefinition) => {
          Row() {
            Image(this.providerIcon(p.id))
              .width(40)
              .height(40)
              .borderRadius(10)
              .backgroundColor(skinColor('fill'))
            Column() {
              Text(p.name)
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
            }
            .margin({ left: 12 })
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            if (this.recordIndex(p.id) >= 0) {
              Text('已添加')
                .fontSize(11)
                .fontColor(skinColor('status_good'))
                .backgroundColor(skinColor('accent_soft'))
                .border({ width: 1, color: skinColor('accent_outline') })
                .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                .borderRadius(12)
            } else {
              Text('›')
                .fontSize(20)
                .fontColor(skinColor('icon_muted'))
            }
          }
          .width('92%')
          .padding(10)
          .margin({ bottom: 6 })
          .backgroundColor(skinColor('surface_row'))
          .borderRadius(12)
          .onClick(() => {
            this.onPickProvider(p.id);
          })
        }, (p: ProviderDefinition) => p.id)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }
}
