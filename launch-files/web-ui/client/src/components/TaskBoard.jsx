import React, { useMemo } from 'react';
import { useOrchestrator } from '../context/OrchestratorContext';

const STATUS_CONFIG = {
  blocked: {
    title: 'Blocked',
    color: 'red',
    bgColor: 'bg-red-900/20',
    borderColor: 'border-red-800',
    icon: '🚫',
  },
  pending: {
    title: 'Ready',
    color: 'blue',
    bgColor: 'bg-blue-900/20',
    borderColor: 'border-blue-800',
    icon: '⏳',
  },
  running: {
    title: 'Running',
    color: 'yellow',
    bgColor: 'bg-yellow-900/20',
    borderColor: 'border-yellow-800',
    icon: '⚡',
  },
  completed: {
    title: 'Completed',
    color: 'green',
    bgColor: 'bg-green-900/20',
    borderColor: 'border-green-800',
    icon: '✅',
  },
  approved: {
    title: 'Approved',
    color: 'green',
    bgColor: 'bg-green-900/20',
    borderColor: 'border-green-800',
    icon: '✅',
  },
};

function TaskCard({ task }) {
  const status = task.currentStatus || task.status || 'pending';
  const config = STATUS_CONFIG[status] || STATUS_CONFIG.pending;

  // Check if task is blocked by dependencies
  const isBlocked = status === 'pending' && task.depends_on?.length > 0;

  return (
    <div className={`p-3 rounded-lg border ${config.bgColor} ${config.borderColor} mb-2`}>
      <div className="flex items-start justify-between mb-2">
        <span className="text-xs font-mono text-gray-400">{task.id}</span>
        <span className={`px-2 py-0.5 rounded text-xs font-medium ${
          status === 'running' ? 'bg-yellow-600 text-yellow-100' :
          status === 'completed' || status === 'approved' ? 'bg-green-600 text-green-100' :
          isBlocked ? 'bg-red-600 text-red-100' :
          'bg-blue-600 text-blue-100'
        }`}>
          {task.agent}
        </span>
      </div>

      <p className="text-sm text-white mb-2 line-clamp-3">
        {task.description}
      </p>

      <div className="flex items-center justify-between text-xs text-gray-400">
        <span className="font-mono">{task.branch}</span>
        {task.runningAgent && (
          <span className="text-yellow-400">
            by {task.runningAgent}
          </span>
        )}
      </div>

      {task.depends_on?.length > 0 && (
        <div className="mt-2 pt-2 border-t border-gray-700">
          <span className="text-xs text-gray-500">
            Depends on: {task.depends_on.join(', ')}
          </span>
        </div>
      )}
    </div>
  );
}

function Column({ title, icon, tasks, color, count }) {
  const colorClasses = {
    red: 'border-red-600',
    blue: 'border-blue-600',
    yellow: 'border-yellow-600',
    green: 'border-green-600',
  };

  return (
    <div className="flex-1 min-w-[280px] max-w-[350px]">
      <div className={`flex items-center gap-2 mb-4 pb-2 border-b-2 ${colorClasses[color]}`}>
        <span>{icon}</span>
        <h3 className="font-semibold text-white">{title}</h3>
        <span className="ml-auto px-2 py-0.5 bg-gray-700 rounded text-xs text-gray-300">
          {count}
        </span>
      </div>

      <div className="space-y-2 overflow-auto max-h-[calc(100vh-280px)]">
        {tasks.length === 0 ? (
          <div className="text-center py-8 text-gray-500 text-sm">
            No tasks
          </div>
        ) : (
          tasks.map(task => <TaskCard key={task.id} task={task} />)
        )}
      </div>
    </div>
  );
}

export default function TaskBoard() {
  const { tasks } = useOrchestrator();

  // Group tasks by status
  const groupedTasks = useMemo(() => {
    const groups = {
      blocked: [],
      pending: [],
      running: [],
      completed: [],
    };

    for (const task of tasks) {
      const status = task.currentStatus || task.status || 'pending';

      if (status === 'completed' || status === 'approved') {
        groups.completed.push(task);
      } else if (status === 'running') {
        groups.running.push(task);
      } else if (task.depends_on?.length > 0) {
        // Check if dependencies are met
        const depsCompleted = task.depends_on.every(depId => {
          const depTask = tasks.find(t => t.id === depId);
          const depStatus = depTask?.currentStatus || depTask?.status;
          return depStatus === 'completed' || depStatus === 'approved';
        });

        if (depsCompleted) {
          groups.pending.push(task);
        } else {
          groups.blocked.push(task);
        }
      } else {
        groups.pending.push(task);
      }
    }

    return groups;
  }, [tasks]);

  return (
    <div className="flex gap-6 overflow-x-auto pb-4">
      <Column
        title="Blocked"
        icon="🚫"
        color="red"
        tasks={groupedTasks.blocked}
        count={groupedTasks.blocked.length}
      />
      <Column
        title="Ready"
        icon="⏳"
        color="blue"
        tasks={groupedTasks.pending}
        count={groupedTasks.pending.length}
      />
      <Column
        title="Running"
        icon="⚡"
        color="yellow"
        tasks={groupedTasks.running}
        count={groupedTasks.running.length}
      />
      <Column
        title="Completed"
        icon="✅"
        color="green"
        tasks={groupedTasks.completed}
        count={groupedTasks.completed.length}
      />
    </div>
  );
}
