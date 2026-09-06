import '../../shooting_script/domain/script_asset_slot_policy.dart';
import 'replicate_models.dart';

/// Product IDs and sort orders remain compatible with saved asset bindings.
class PairedWardrobePolicy {
  const PairedWardrobePolicy._();

  static List<ReplicateDetectedSubject> subjects(
    List<ReplicateDetectedSubject> detected,
    int personCount,
  ) {
    final people = {
      for (final subject in detected)
        if (subject.type == ReplicateSubjectType.person)
          subject.slotIndex: subject,
    };
    final count = personCount > people.length ? personCount : people.length;
    return [
      for (var index = 0; index < count.clamp(0, 20); index++) ...[
        (people[index] ??
                ReplicateDetectedSubject(
                  id: 'person:$index',
                  type: ReplicateSubjectType.person,
                  label: '',
                  slotIndex: index,
                ))
            .copyWith(
              label: '模特${ScriptAssetSlotPolicy.characterSuffix(index)}',
            ),
        ReplicateDetectedSubject(
          id: 'product:$index',
          type: ReplicateSubjectType.product,
          label: '服装参考${ScriptAssetSlotPolicy.characterSuffix(index)}',
          slotIndex: index,
          location: people[index]?.location.trim().isNotEmpty == true
              ? people[index]!.location
              : '画面从左到右第${index + 1}位',
          relationship: '穿着在画面从左到右第${index + 1}位模特身上，仅替换参考服装对应区域',
          // Only an already normalized wardrobe slot can carry an explicit
          // removal decision; legacy shoes/props are not whole outfits.
          decision:
              detected
                  .where(
                    (subject) =>
                        subject.type == ReplicateSubjectType.product &&
                        subject.slotIndex == index &&
                        (subject.label.startsWith('服装参考') ||
                            subject.decision !=
                                ReplicateSubjectDecision.remove),
                  )
                  .firstOrNull
                  ?.decision ??
              ReplicateSubjectDecision.undecided,
        ),
      ],
    ];
  }

  static const prompt =
      '【服装分区与真实穿着】服装参考A只穿在图片1从左到右第1位模特A身上，B、C及后续编号严格一一对应；'
      '模特身份槽为空时保留该人物原身份，仍须执行同编号服装替换。不得串穿、互换、合并或复制人物。'
      '上装只替换上身对应衣物，下装只替换裤装或裙装，连体衣/连衣裙替换其覆盖区域，明确的套装替换成套衣物；'
      '未指定的内搭、下装或上装、鞋包与配饰保留原帧，不因参考里出现其他衣物而擅自整套替换。'
      '完整去除待换旧衣款式、颜色、花纹和材质，不能仅换色或叠穿旧衣。'
      '平铺图、人台图须还原真实穿着体积与版型，不能粘贴平铺轮廓、衣架或人台；'
      '他人穿着图只提取指定衣物，禁止引入其脸、身体、姿势、配饰或背景。'
      '保持新衣领袖、衣长、门襟、口袋、缝线、纹样比例和设计性褶裥；'
      '随目标人物体型、动作、重力和接触点重建自然受力褶皱，不可见区域只作最小一致补全。';
}
