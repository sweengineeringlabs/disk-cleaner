package main.features.config.api;

/** Scans filesystem for projects matching marker files. */
public interface ProjectScanner {
    String[] scanForProjects(String[] markers);
    String[][] filterProjects(String[] found);
    String relativePath(String fullPath);
    boolean isCancelled();
}
