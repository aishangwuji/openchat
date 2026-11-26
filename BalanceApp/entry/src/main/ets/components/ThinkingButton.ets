/*
 * ThinkingButton.ets
 *
 * 深度思考开关组件 —— 对齐官方输入框内的能力胶囊（淡蓝底 + 品牌蓝文字 + 图标）：
 * 1. 严格禁用所有 Emoji 表情符与额外修饰文本（无表情、无 ON 标签）；
 * 2. 开启时淡蓝底/蓝字/细蓝边，关闭时素灰底/次级文字；
 * 3. DeepSeek 固定支持思考模式。
 *
 * 遵循 ArkTS 严格模式规范：无 any/unknown，无解构，强类型定义。
 */

import { isThinkingSupported } from '../services/ProviderRegistry';
import { skinColor } from '../services/SkinService';

@Component
export struct ThinkingButton {
  /** 皮肤版本号：皮肤或明暗切换时自增（SkinService），驱动本组件按新调色板重绘。 */
  @StorageProp('skin_version') skinVersion: number = 0;
  @Prop isEnabled: boolean = false;
  @Prop providerId: string = 'deepseek';
  @Prop modelId: string = '';
  onToggle: (enabled: boolean) => void = () => {};

  private isVisible(): boolean {
    return isThinkingSupported(this.providerId, this.modelId);
  }

  build() {
    if (this.isVisible()) {
      Row() {
        Row() {
          Image($r('app.media.ic_atom'))
            .width(13)
            .height(13)
            .margin({ right: 5 })
          Text('深度思考')
            .fontSize(13)
            .fontColor(this.isEnabled ? skinColor('pill_search_text') : skinColor('text_secondary'))
            .fontWeight(this.isEnabled ? FontWeight.Medium : FontWeight.Normal)
        }
        .height(30)
        .padding({ left: 12, right: 12 })
        .backgroundColor(this.isEnabled ? skinColor('pill_search_bg') : skinColor('chat_fill'))
        .borderRadius(16)
        .borderWidth(1)
        .borderColor(this.isEnabled ? skinColor('pill_search_border') : '#00000000')
        .animation({ duration: 200, curve: Curve.FastOutSlowIn })
        .onClick(() => {
          const nextState: boolean = !this.isEnabled;
          this.onToggle(nextState);
        })
      }
      .justifyContent(FlexAlign.Start)
      .margin({ right: 8 })
    }
  }
}
