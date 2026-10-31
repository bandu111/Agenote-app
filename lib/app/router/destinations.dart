import 'package:flutter/material.dart';

enum Destination {
  calendar(
    'calendar',
    '日程',
    Icons.calendar_today_outlined,
    '言枢内部日程将在这里展示。系统日历尚未接入。',
  ),
  tasks(
    'tasks',
    '待办',
    Icons.check_circle_outline,
    '查看个人待办和言枢建议；建议不会自动成为已创建的事项。',
  ),
  outcomes('outcomes', '成果', Icons.auto_awesome_outlined, '草稿、报告与版本将在这里汇集。'),
  records('records', '记录', Icons.history_outlined, '回顾会话、有效决定、双方承诺与持续目标。'),
  sessions('sessions', '历史会话', Icons.chat_bubble_outline, '还没有会话记录。'),
  decisions('decisions', '有效决定', Icons.fact_check_outlined, '还没有已确认的决定。'),
  commitments(
    'commitments',
    '双方承诺',
    Icons.handshake_outlined,
    '承诺的声称完成与客观核实将分别展示。',
  ),
  goals('goals', '持续目标', Icons.flag_outlined, '目标、约束与成功标准将在这里持续跟踪。'),
  calendarDay('calendar-day', '日视图', Icons.today_outlined, '还没有已保存的日程。'),
  calendarEdit(
    'calendar-edit',
    '编辑日程',
    Icons.edit_calendar_outlined,
    '日程编辑暂未开放。',
  ),
  taskSuggestions(
    'task-suggestions',
    'AI 建议待办',
    Icons.lightbulb_outline,
    '还没有待办建议。',
  ),
  taskDetail('task-detail', '任务详情', Icons.task_alt, '待办详情暂未开放。'),
  outcomeDetail(
    'outcome-detail',
    '成果详情',
    Icons.description_outlined,
    '成果预览和版本管理暂未开放。',
  ),
  personal('personal', '个人资料', Icons.person_outline, '账号服务尚未接入。'),
  workspace('workspace', '工作空间与项目', Icons.workspaces_outline, '工作空间与项目切换暂未开放。'),
  sources('sources', '已授权资料', Icons.folder_outlined, '目前没有授权任何资料。'),
  devices('devices', '设备与语音输入', Icons.mic_none_outlined, '尚未检测设备，语音采集尚未接入。'),
  permissions(
    'permissions',
    '自动执行权限',
    Icons.shield_outlined,
    '自动执行默认关闭，权限服务接入后才可开启。',
  ),
  notifications(
    'notifications',
    '通知与勿扰',
    Icons.notifications_none,
    '通知与勿扰设置暂未开放。',
  ),
  privacy(
    'privacy',
    '隐私与安全',
    Icons.lock_outline,
    '此基础版本未采集音频，也未上传资料。数据管理功能暂未开放。',
  ),
  about(
    'about',
    '关于言枢',
    Icons.info_outline,
    '理解当下，提前一步。\n主动式 AI 行动伙伴 · 基础开发版本',
  ),
  createCalendar(
    'create-calendar',
    '新建日程',
    Icons.add_circle_outline,
    '日程创建暂未开放，当前不会保存任何日程。',
  ),
  createTask('create-task', '新建待办', Icons.add_task, '待办创建暂未开放，当前不会保存任何待办。'),
  createNote(
    'create-note',
    '新建笔记',
    Icons.note_add_outlined,
    '笔记编辑暂未开放，当前不会保存任何笔记。',
  ),
  delegate(
    'delegate',
    '交代给言枢',
    Icons.arrow_outward,
    '交代事项暂未开放，当前不会启动 AI 或执行操作。',
  ),
  conversation(
    'conversation',
    '开始会话',
    Icons.graphic_eq,
    '授权会话暂未开放，当前不会开启麦克风或采集音频。',
  );

  const Destination(this.route, this.title, this.icon, this.description);
  final String route;
  final String title;
  final IconData icon;
  final String description;
  static const categories = [calendar, tasks, outcomes, records];
  static const settings = [
    personal,
    workspace,
    sources,
    devices,
    permissions,
    notifications,
    privacy,
    about,
  ];
  static const quickActions = [
    createCalendar,
    createTask,
    createNote,
    delegate,
  ];
  List<Destination> get children => switch (this) {
    calendar => [calendarDay, createCalendar, calendarEdit],
    tasks => [createTask, taskSuggestions, taskDetail],
    outcomes => [outcomeDetail],
    records => [sessions, decisions, commitments, goals],
    _ => [],
  };
}

abstract final class AppRoutes {
  static const home = '/home';
  static const affairs = '/affairs';
  static const knowledge = '/knowledge';
  static const profile = '/profile';
  static const independent = ['startup', 'login', 'register', 'setup'];
}
