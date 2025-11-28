import React, { useState, useRef, useEffect } from 'react';
import { useOrchestrator } from '../context/OrchestratorContext';

export default function ProjectSelector() {
  const { projects, selectedProject, selectProject, fetchProjects } = useOrchestrator();
  const [isOpen, setIsOpen] = useState(false);
  const dropdownRef = useRef(null);

  // Close dropdown when clicking outside
  useEffect(() => {
    function handleClickOutside(event) {
      if (dropdownRef.current && !dropdownRef.current.contains(event.target)) {
        setIsOpen(false);
      }
    }
    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, []);

  const currentProject = projects.find(p => p.name === selectedProject);

  return (
    <div className="relative" ref={dropdownRef}>
      <button
        onClick={() => setIsOpen(!isOpen)}
        className="flex items-center gap-2 px-4 py-2 bg-gray-800 hover:bg-gray-700 rounded-lg transition-colors"
      >
        <span className="text-sm text-gray-300">
          {currentProject?.description?.slice(0, 40) || selectedProject || 'Select project...'}
          {currentProject?.description?.length > 40 && '...'}
        </span>
        <svg
          className={`w-4 h-4 text-gray-400 transition-transform ${isOpen ? 'rotate-180' : ''}`}
          fill="none"
          stroke="currentColor"
          viewBox="0 0 24 24"
        >
          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 9l-7 7-7-7" />
        </svg>
      </button>

      {isOpen && (
        <div className="absolute top-full left-0 mt-2 w-80 bg-gray-800 border border-gray-700 rounded-lg shadow-xl z-50">
          <div className="p-2 border-b border-gray-700 flex items-center justify-between">
            <span className="text-xs text-gray-400 uppercase tracking-wide">Projects</span>
            <button
              onClick={fetchProjects}
              className="text-xs text-blue-400 hover:text-blue-300"
            >
              Refresh
            </button>
          </div>

          <div className="max-h-64 overflow-auto">
            {projects.length === 0 ? (
              <div className="p-4 text-center text-gray-400 text-sm">
                No projects found
              </div>
            ) : (
              projects.map((project) => (
                <button
                  key={project.name}
                  onClick={() => {
                    selectProject(project.name);
                    setIsOpen(false);
                  }}
                  className={`w-full text-left p-3 hover:bg-gray-700 transition-colors ${
                    project.name === selectedProject ? 'bg-gray-700' : ''
                  }`}
                >
                  <div className="flex items-start justify-between">
                    <div className="flex-1 min-w-0">
                      <div className="text-sm text-white truncate">
                        {project.description || project.name}
                      </div>
                      <div className="text-xs text-gray-400 mt-1">
                        {project.name}
                      </div>
                    </div>
                    {project.totalTasks !== undefined && (
                      <div className="ml-2 text-xs text-gray-400">
                        {project.completedTasks || 0}/{project.totalTasks}
                      </div>
                    )}
                  </div>
                  {project.totalTasks > 0 && (
                    <div className="mt-2 h-1 bg-gray-600 rounded-full overflow-hidden">
                      <div
                        className="h-full bg-green-500"
                        style={{
                          width: `${((project.completedTasks || 0) / project.totalTasks) * 100}%`
                        }}
                      />
                    </div>
                  )}
                </button>
              ))
            )}
          </div>
        </div>
      )}
    </div>
  );
}
